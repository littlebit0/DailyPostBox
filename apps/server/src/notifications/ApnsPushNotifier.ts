import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { connect, constants, type ClientHttp2Session } from "node:http2";
import type { IncomingMessageSummary } from "../domain/types.js";
import type { PushNotifier, PushTarget } from "./PushNotifier.js";

export interface ApnsConfig {
  privateKeyPem: string;
  keyId: string;
  teamId: string;
  topic: string;
  production: boolean;
}

// APNs rejects provider tokens older than an hour and throttles ones
// refreshed more often than every 20 minutes.
const tokenLifetimeMs = 50 * 60_000;
const requestTimeoutMs = 10_000;
const retryDelaysMs = [1_000, 5_000];
// APNs rejects alert payloads above 4 KB.
const maxPayloadBytes = 4_096;

export class ApnsPushNotifier implements PushNotifier {
  private readonly key: KeyObject;
  private cachedToken?: { value: string; issuedAt: number };

  constructor(
    private readonly config: ApnsConfig,
    private readonly removeTarget: (target: PushTarget) => Promise<void>,
    private readonly openSession: (origin: string) => ClientHttp2Session = connect,
    private readonly wait: (ms: number) => Promise<void> = delay
  ) {
    this.key = createPrivateKey(config.privateKeyPem);
  }

  async notifyNewMessage(
    targets: PushTarget[],
    message: IncomingMessageSummary
  ): Promise<void> {
    const appleTargets = targets.filter(
      (target) => target.platform === "macos" || target.platform === "ios"
    );
    if (appleTargets.length === 0) return;

    const body = JSON.stringify(apnsPayload(message));
    await Promise.all(appleTargets.map((target) => this.deliver(target, body)));
  }

  // Never rejects: transport errors, timeouts, throttling and APNs outages
  // are retried a bounded number of times on a fresh connection.
  private async deliver(target: PushTarget, body: string): Promise<void> {
    for (let attempt = 0; ; attempt += 1) {
      let result: { status: number; reason?: string };
      try {
        result = await this.sendOnce(target.deviceToken, body);
      } catch (error) {
        result = { status: 0, reason: error instanceof Error ? error.message : String(error) };
      }
      if (result.status === 200) return;

      const retryable = result.status === 0 || result.status === 429 || result.status >= 500;
      if (retryable && attempt < retryDelaysMs.length) {
        await this.wait(retryDelaysMs[attempt]);
        continue;
      }

      console.warn("push:apns-rejected", {
        status: result.status,
        reason: result.reason,
        device: target.deviceToken.slice(0, 8)
      });
      if (isDeadToken(result.status, result.reason)) {
        await this.removeTarget(target).catch(() => undefined);
      }
      return;
    }
  }

  private async sendOnce(
    deviceToken: string,
    body: string
  ): Promise<{ status: number; reason?: string }> {
    const origin = this.config.production
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";
    const session = this.openSession(origin);
    session.on("error", () => undefined);
    try {
      const result = await this.send(session, deviceToken, body);
      session.close();
      return result;
    } catch (error) {
      // close() waits for a graceful end that a stalled TLS handshake never
      // reaches; destroy() releases the socket.
      session.destroy();
      throw error;
    }
  }

  private send(
    session: ClientHttp2Session,
    deviceToken: string,
    body: string
  ): Promise<{ status: number; reason?: string }> {
    return new Promise((resolve, reject) => {
      const request = session.request({
        [constants.HTTP2_HEADER_METHOD]: "POST",
        [constants.HTTP2_HEADER_PATH]: `/3/device/${deviceToken}`,
        authorization: `bearer ${this.providerToken()}`,
        "apns-topic": this.config.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json"
      });
      let status = 0;
      let response = "";
      request.setEncoding("utf8");
      request.on("response", (headers) => {
        status = Number(headers[constants.HTTP2_HEADER_STATUS]);
      });
      request.on("data", (chunk: string) => {
        response += chunk;
      });
      request.on("end", () => {
        let reason: string | undefined;
        try {
          reason = response ? (JSON.parse(response) as { reason?: string }).reason : undefined;
        } catch {
          reason = undefined;
        }
        resolve({ status, reason });
      });
      request.on("error", reject);
      request.setTimeout(requestTimeoutMs, () => {
        request.close(constants.NGHTTP2_CANCEL);
        reject(new Error("APNs request timed out"));
      });
      request.end(body);
    });
  }

  private providerToken(): string {
    const now = Date.now();
    if (this.cachedToken && now - this.cachedToken.issuedAt < tokenLifetimeMs) {
      return this.cachedToken.value;
    }
    const value = apnsProviderToken(
      this.key,
      this.config.keyId,
      this.config.teamId,
      Math.floor(now / 1000)
    );
    this.cachedToken = { value, issuedAt: now };
    return value;
  }
}

export function apnsProviderToken(
  key: KeyObject,
  keyId: string,
  teamId: string,
  issuedAtSeconds: number
): string {
  const header = base64Url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = base64Url(JSON.stringify({ iss: teamId, iat: issuedAtSeconds }));
  const signature = sign("sha256", Buffer.from(`${header}.${claims}`), {
    key,
    dsaEncoding: "ieee-p1363"
  });
  return `${header}.${claims}.${signature.toString("base64url")}`;
}

export function apnsPayload(message: IncomingMessageSummary) {
  const payload = {
    aps: {
      alert: {
        title: message.from || "새 메일",
        body: message.subject || "(제목 없음)"
      },
      sound: "default",
      "thread-id": message.accountId
    },
    accountId: message.accountId,
    providerMessageId: message.providerMessageId
  };
  // Shorten the body first, then the title, until the payload fits.
  const alert = payload.aps.alert;
  for (const field of ["body", "title"] as const) {
    // JSON escaping can add bytes, so re-measure until it fits.
    for (let attempt = 0; attempt < 4; attempt += 1) {
      const overflow = Buffer.byteLength(JSON.stringify(payload)) - maxPayloadBytes;
      if (overflow <= 0) return payload;
      alert[field] = truncateUtf8(
        alert[field],
        Buffer.byteLength(alert[field]) - overflow - 8
      );
    }
  }
  return payload;
}

function truncateUtf8(value: string, maxBytes: number): string {
  if (Buffer.byteLength(value) <= maxBytes) return value;
  const ellipsisBytes = 3;
  let result = "";
  let bytes = 0;
  for (const char of value) {
    const charBytes = Buffer.byteLength(char);
    if (bytes + charBytes + ellipsisBytes > maxBytes) break;
    result += char;
    bytes += charBytes;
  }
  return `${result}…`;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function isDeadToken(status: number, reason?: string): boolean {
  return status === 410 ||
    (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic"));
}

function base64Url(value: string): string {
  return Buffer.from(value).toString("base64url");
}
