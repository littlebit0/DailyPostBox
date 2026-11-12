import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { generateKeyPairSync, verify } from "node:crypto";
import test from "node:test";
import type { ClientHttp2Session } from "node:http2";
import {
  ApnsPushNotifier,
  apnsPayload,
  apnsProviderToken
} from "../src/notifications/ApnsPushNotifier.js";
import type { PushTarget } from "../src/notifications/PushNotifier.js";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();

const message = {
  accountId: "account-1",
  providerMessageId: "42",
  mailbox: "INBOX",
  from: "sender@example.com",
  subject: "Hello",
  receivedAt: new Date(),
  hasAttachments: false
};

test("signs an ES256 provider token APNs can verify", () => {
  const token = apnsProviderToken(privateKey, "KEY123", "TEAM456", 1_700_000_000);
  const [header, claims, signature] = token.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url").toString()), {
    alg: "ES256",
    kid: "KEY123"
  });
  assert.deepEqual(JSON.parse(Buffer.from(claims, "base64url").toString()), {
    iss: "TEAM456",
    iat: 1_700_000_000
  });
  assert.ok(verify(
    "sha256",
    Buffer.from(`${header}.${claims}`),
    { key: publicKey, dsaEncoding: "ieee-p1363" },
    Buffer.from(signature, "base64url")
  ));
});

type FakeResponse = { status: number; body?: string } | "error" | "hang";

function fakeSession(responses: Record<string, FakeResponse | FakeResponse[]>) {
  const requests: { headers: Record<string, string>; body: string }[] = [];
  let origin = "";
  const session = Object.assign(new EventEmitter(), {
    request(headers: Record<string, string>) {
      let onTimeout: (() => void) | undefined;
      const stream = Object.assign(new EventEmitter(), {
        setEncoding: () => undefined,
        setTimeout: (_ms: number, callback: () => void) => {
          onTimeout = callback;
        },
        close: () => undefined,
        end(body: string) {
          requests.push({ headers, body });
          const token = headers[":path"].split("/").at(-1)!;
          const scripted = responses[token] ?? { status: 200 };
          const response = Array.isArray(scripted)
            ? scripted.shift() ?? { status: 200 }
            : scripted;
          setImmediate(() => {
            if (response === "hang") {
              onTimeout?.();
              return;
            }
            if (response === "error") {
              stream.emit("error", new Error("ECONNRESET"));
              return;
            }
            stream.emit("response", { ":status": response.status });
            if (response.body) stream.emit("data", response.body);
            stream.emit("end");
          });
        }
      });
      return stream;
    },
    close: () => undefined
  });
  return {
    requests,
    origin: () => origin,
    open: (value: string) => {
      origin = value;
      return session as unknown as ClientHttp2Session;
    }
  };
}

test("sends alerts to Apple devices and drops dead tokens", async () => {
  const removed: PushTarget[] = [];
  const session = fakeSession({
    deadtoken: { status: 410, body: JSON.stringify({ reason: "Unregistered" }) }
  });
  const notifier = new ApnsPushNotifier(
    { privateKeyPem: pem, keyId: "KEY123", teamId: "TEAM456", topic: "com.dailypostbox.app", production: false },
    async (target) => {
      removed.push(target);
    },
    session.open,
    async () => undefined
  );

  await notifier.notifyNewMessage([
    { userId: "demo-user", platform: "macos", deviceToken: "goodtoken" },
    { userId: "demo-user", platform: "macos", deviceToken: "deadtoken" },
    { userId: "demo-user", platform: "android", deviceToken: "androidtoken" }
  ], message);

  assert.equal(session.origin(), "https://api.sandbox.push.apple.com");
  assert.equal(session.requests.length, 2);
  const [first] = session.requests;
  assert.equal(first.headers["apns-topic"], "com.dailypostbox.app");
  assert.equal(first.headers["apns-push-type"], "alert");
  assert.match(first.headers.authorization, /^bearer [^.]+\.[^.]+\.[^.]+$/);
  assert.deepEqual(JSON.parse(first.body).aps.alert, {
    title: "sender@example.com",
    body: "Hello"
  });
  assert.deepEqual(removed.map((target) => target.deviceToken), ["deadtoken"]);
});

test("retries timeouts and transport errors without rejecting", async () => {
  const session = fakeSession({
    flaky: ["error", "hang", { status: 200 }],
    down: ["hang", "hang", "hang"]
  });
  const notifier = new ApnsPushNotifier(
    { privateKeyPem: pem, keyId: "KEY123", teamId: "TEAM456", topic: "com.dailypostbox.app", production: false },
    async () => undefined,
    session.open,
    async () => undefined
  );

  await notifier.notifyNewMessage([
    { userId: "demo-user", platform: "macos", deviceToken: "flaky" },
    { userId: "demo-user", platform: "macos", deviceToken: "down" }
  ], message);

  const attempts = (token: string) =>
    session.requests.filter((request) => request.headers[":path"].endsWith(token)).length;
  assert.equal(attempts("flaky"), 3);
  assert.equal(attempts("down"), 3);
});

test("keeps long alerts within the APNs payload limit", () => {
  const payload = apnsPayload({
    ...message,
    from: "sender@example.com, ".repeat(300),
    subject: "메일\"".repeat(700)
  });
  assert.ok(Buffer.byteLength(JSON.stringify(payload)) <= 4_096);
  assert.ok(payload.aps.alert.body.endsWith("…"));
  assert.equal(apnsPayload(message).aps.alert.body, "Hello");
});
