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

export class ApnsPushNotifier implements PushNotifier {
  private readonly key: KeyObject;
  private cachedToken?: { value: string; issuedAt: number };

  constructor(
    private readonly config: ApnsConfig,
    private readonly removeTarget: (target: PushTarget) => Promise<void>,
    private readonly openSession: (origin: string) => ClientHttp2Session = connect
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

    const origin = this.config.production
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";
    const session = this.openSession(origin);
    session.on("error", () => undefined);
    const body = JSON.stringify(apnsPayload(message));

    try {
      await Promise.all(appleTargets.map(async (target) => {
        const result = await this.send(session, target.deviceToken, body);
        if (result.status === 200) return;
        console.warn("push:apns-rejected", {
          status: result.status,
          reason: result.reason,
          device: target.deviceToken.slice(0, 8)
        });
        if (isDeadToken(result.status, result.reason)) {
          await this.removeTarget(target);
        }
      }));
    } finally {
      session.close();
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
  return {
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
}

function isDeadToken(status: number, reason?: string): boolean {
  return status === 410 ||
    (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic"));
}

function base64Url(value: string): string {
  return Buffer.from(value).toString("base64url");
}
