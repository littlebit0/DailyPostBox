import assert from "node:assert/strict";
import test from "node:test";
import { Readable } from "node:stream";
import Fastify from "fastify";
import { registerRoutes } from "../src/api/routes.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";

async function build() {
  const now = new Date();
  const accounts = new InMemoryAccountRepository();
  await accounts.addAccount({
    id: "a1",
    userId: "demo-user",
    providerId: "naver",
    emailAddress: "u@example.test",
    authMode: "app-password",
    incomingProtocol: "imap",
    encryptedSecretRef: "x",
    syncStatus: "idle",
    createdAt: now,
    updatedAt: now
  });
  await accounts.saveIncomingMessage({
    accountId: "a1",
    providerMessageId: "7",
    mailbox: "INBOX",
    from: "",
    subject: "",
    receivedAt: now,
    hasAttachments: true
  });
  let downloads = 0;
  const app = Fastify();
  await registerRoutes(app, {
    accounts,
    fetchMessageSummary: async (_account: unknown, id: string) => id === "9"
      ? { accountId: "a1", providerMessageId: "9", mailbox: "INBOX", from: "", subject: "", receivedAt: now, hasAttachments: true }
      : null,
    downloadAttachment: async () => {
      downloads++;
      return {
        filename: "a.txt",
        contentType: "text/plain",
        stream: Readable.from([Buffer.from("abc")]),
        close: async () => undefined
      };
    }
  } as never);
  return { app, downloads: () => downloads };
}

const url = "/accounts/a1/messages/7/attachments/2";

test("loopback may download attachments", async () => {
  const { app } = await build();
  for (const remoteAddress of ["127.0.0.1", "::1", "::ffff:127.0.0.1"]) {
    assert.equal((await app.inject({ url, remoteAddress })).statusCode, 200);
  }
});

test("remote callers get 403 and nothing is fetched", async () => {
  const { app, downloads } = await build();
  const res = await app.inject({ url, remoteAddress: "192.168.0.5" });
  assert.equal(res.statusCode, 403);
  assert.equal(downloads(), 0);
});

test("Origin header or non-loopback Host gets 403 even from loopback", async () => {
  const { app, downloads } = await build();
  const remoteAddress = "127.0.0.1";
  const origin = await app.inject({ url, remoteAddress, headers: { origin: "https://evil.example" } });
  assert.equal(origin.statusCode, 403);
  const host = await app.inject({ url, remoteAddress, headers: { host: "evil.example" } });
  assert.equal(host.statusCode, 403);
  assert.equal(downloads(), 0);
  const ok = await app.inject({ url, remoteAddress, headers: { host: "[::1]:8080" } });
  assert.equal(ok.statusCode, 200);
});

test("ALLOW_REMOTE_MAIL_ACCESS=true opts remote callers in", async () => {
  process.env.ALLOW_REMOTE_MAIL_ACCESS = "true";
  try {
    const { app } = await build();
    const res = await app.inject({ url, remoteAddress: "192.168.0.5" });
    assert.equal(res.statusCode, 200);
  } finally {
    delete process.env.ALLOW_REMOTE_MAIL_ACCESS;
  }
});

test("unimported search results download locally but stay behind the search gate", async () => {
  const unstored = "/accounts/a1/messages/9/attachments/2";
  const { app } = await build();
  assert.equal((await app.inject({ url: unstored, remoteAddress: "127.0.0.1" })).statusCode, 200);
  process.env.ALLOW_REMOTE_MAIL_ACCESS = "true";
  try {
    const res = await app.inject({ url: unstored, remoteAddress: "192.168.0.5" });
    assert.equal(res.statusCode, 404);
  } finally {
    delete process.env.ALLOW_REMOTE_MAIL_ACCESS;
  }
});
