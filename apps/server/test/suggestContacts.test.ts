import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import type { IncomingMessageSummary, MailAccount } from "../src/domain/types.js";
import { suggestContacts } from "../src/contacts/suggestContacts.js";
import { SendQueue } from "../src/mail/SendQueue.js";
import { InMemoryAccountRepository, type SentRecipient } from "../src/workers/AccountRepository.js";

process.env.GOOGLE_OAUTH_CLIENT_ID ??= "test-client";
const { registerRoutes } = await import("../src/api/routes.js");

function sent(address: string, day: number, count = 1): SentRecipient {
  return { accountId: "a", address, count, lastSentAt: new Date(Date.UTC(2026, 10, day)) };
}

test("ranks by frequency then recency and matches substrings case-insensitively", () => {
  const result = suggestContacts(
    [sent("alice@example.test", 2, 2), sent("alan@example.test", 22, 2), sent("bob@example.test", 21)],
    "AL"
  );
  assert.deepEqual(
    result.map((item) => [item.address, item.count]),
    [["alan@example.test", 2], ["alice@example.test", 2]]
  );
  assert.equal(result[0].lastSeenAt, "2026-11-22T00:00:00.000Z");
});

test("empty query and limit", () => {
  assert.deepEqual(suggestContacts([sent("a@example.test", 1)], " "), []);
  const many = Array.from({ length: 5 }, (_, i) => sent(`u${i}@example.test`, i + 1));
  assert.equal(suggestContacts(many, "u", 3).length, 3);
});

test("excludes non-repliable addresses but keeps normal ones", () => {
  const blocked = [
    "no_reply@email.apple.com", "noreply@x.test", "noreply+tag@x.test", "no-reply@x.test",
    "do.not.reply@x.test", "donotreply@x.test", "do-not-reply@x.test", "notreply@x.test",
    "mailer-daemon@x.test", "postmaster@x.test", "bounce@x.test", "bounces+abc123@x.test"
  ];
  const result = suggestContacts(
    [...blocked.map((address, i) => sent(address, i + 1)), sent("ann@example.test", 1), sent("replyguy@x.test", 2)],
    "@"
  );
  assert.deepEqual(result.map((item) => item.address).sort(), ["ann@example.test", "replyguy@x.test"]);
});

test("suggests only sent recipients, never inbound senders", async () => {
  const now = new Date();
  const account: MailAccount = {
    id: "account-1",
    userId: "demo-user",
    providerId: "custom",
    emailAddress: "me@example.test",
    authMode: "app-password",
    incomingProtocol: "imap",
    encryptedSecretRef: "secret",
    syncStatus: "idle",
    createdAt: now,
    updatedAt: now
  };
  const accounts = new InMemoryAccountRepository();
  await accounts.addAccount(account);
  const inbound: IncomingMessageSummary = {
    accountId: account.id,
    providerMessageId: "m1",
    mailbox: "INBOX",
    from: "alice@company.test.evil.example",
    subject: "",
    receivedAt: now,
    hasAttachments: false
  };
  await accounts.saveIncomingMessage(inbound);

  const sender = {
    testConnection: async () => {},
    send: async (_account: MailAccount, draft: { to: string[] }) => ({ accepted: draft.to, rejected: [] })
  };
  const sendQueue = new SendQueue(sender as never);
  const app = Fastify();
  await registerRoutes(app, {
    accounts,
    sendQueue,
    validateAccount: async () => {},
    startAccountSync: async () => {},
    resumeAccountSync: async () => {},
    stopAccountSync: async () => {},
    sender,
    fetchMessageContent: async () => {
      throw new Error("unused");
    }
  });

  const suggest = async () =>
    (await app.inject({ method: "GET", url: "/contacts/suggest?q=alice" })).json() as Array<{ address: string }>;
  assert.deepEqual(await suggest(), []);

  const send = await app.inject({
    method: "POST",
    url: "/mail/send",
    payload: { accountId: account.id, to: ["Alice@company.test"], subject: "hi", text: "hi", delaySeconds: 0 }
  });
  assert.equal(send.statusCode, 202);
  await sendQueue.flush();
  assert.deepEqual((await suggest()).map((item) => item.address), ["alice@company.test"]);

  await accounts.deleteAccount(account.id);
  assert.deepEqual(await accounts.listSentRecipients("demo-user"), []);
});

test("send still returns 202 when saving sent recipients fails", async () => {
  const logs: string[] = [];
  const now = new Date();
  const accounts = new InMemoryAccountRepository();
  await accounts.addAccount({
    id: "account-1",
    userId: "demo-user",
    providerId: "custom",
    emailAddress: "me@example.test",
    authMode: "app-password",
    incomingProtocol: "imap",
    encryptedSecretRef: "secret",
    syncStatus: "idle",
    createdAt: now,
    updatedAt: now
  });
  accounts.recordSentRecipients = async () => {
    throw Object.assign(new Error("ENOSPC: no space left on device"), { code: "ENOSPC" });
  };

  const sender = {
    testConnection: async () => {},
    send: async (_account: MailAccount, draft: { to: string[] }) => ({ accepted: draft.to, rejected: [] })
  };
  const sendQueue = new SendQueue(sender as never);
  const app = Fastify({ logger: { level: "warn", stream: { write: (line: string) => logs.push(line) } } });
  await registerRoutes(app, {
    accounts,
    sendQueue,
    validateAccount: async () => {},
    startAccountSync: async () => {},
    resumeAccountSync: async () => {},
    stopAccountSync: async () => {},
    sender,
    fetchMessageContent: async () => {
      throw new Error("unused");
    }
  });

  const send = await app.inject({
    method: "POST",
    url: "/mail/send",
    payload: { accountId: "account-1", to: ["bob@example.test"], subject: "hi", text: "hi", delaySeconds: 0 }
  });
  assert.equal(send.statusCode, 202);
  await sendQueue.flush();
  assert.equal(sendQueue.status(send.json().id)?.status, "sent");
  const warning = logs.find((line) => line.includes("Failed to save sent recipients"));
  assert.ok(warning?.includes("ENOSPC"));
  assert.ok(!logs.some((line) => line.includes("bob@example.test")));
});

test("contact suggestions are blocked for remote requests", async () => {
  const app = Fastify();
  await registerRoutes(app, { accounts: new InMemoryAccountRepository() } as never);
  const remote = await app.inject({ method: "GET", url: "/contacts/suggest?q=a", remoteAddress: "203.0.113.5" });
  assert.equal(remote.statusCode, 403);
  const browser = await app.inject({ method: "GET", url: "/contacts/suggest?q=a", headers: { origin: "http://evil.test" } });
  assert.equal(browser.statusCode, 403);
});
