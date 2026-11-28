import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import type { MessageFlagChange } from "../src/domain/types.js";
import { registerRoutes } from "../src/api/routes.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";
import { SnoozeStore } from "../src/workers/SnoozeStore.js";

async function setup(failServer = false) {
  const now = new Date();
  const accounts = new InMemoryAccountRepository();
  await accounts.addAccount({
    id: "account-1",
    userId: "demo-user",
    providerId: "naver",
    emailAddress: "user@example.com",
    authMode: "app-password",
    incomingProtocol: "imap",
    encryptedSecretRef: "app-password",
    createdAt: now,
    updatedAt: now
  });
  await accounts.saveIncomingMessage({
    accountId: "account-1",
    providerMessageId: "7",
    mailbox: "INBOX",
    from: "a@example.com",
    subject: "hi",
    receivedAt: now,
    hasAttachments: false,
    seen: false,
    flagged: false
  });
  const calls: Array<[string, MessageFlagChange]> = [];
  const app = Fastify();
  await registerRoutes(app, {
    accounts,
    snoozes: new SnoozeStore(undefined, () => undefined),
    sender: {} as never,
    validateAccount: async () => undefined,
    fetchMessageContent: async () => {
      throw new Error("unused");
    },
    setMessageFlags: async (_account, message, change) => {
      if (failServer) throw new Error("server down");
      calls.push([message.providerMessageId, change]);
    },
    startAccountSync: async () => undefined,
    resumeAccountSync: async () => undefined,
    stopAccountSync: async () => undefined
  });
  return { app, calls };
}

const url = "/accounts/account-1/messages/7/flags";

test("flag change goes to the server and the stored copy", async () => {
  const { app, calls } = await setup();
  const response = await app.inject({
    method: "POST",
    url,
    payload: { seen: true }
  });
  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.json(), { seen: true, flagged: false });
  assert.deepEqual(calls, [["7", { seen: true }]]);

  const list = await app.inject({ method: "GET", url: "/accounts/account-1/messages" });
  assert.equal(list.json()[0].seen, true);
});

test("rejects an empty change and unknown messages", async () => {
  const { app, calls } = await setup();
  // Zod errors become 400 in server.ts's error handler; bare Fastify gives 500.
  const empty = await app.inject({ method: "POST", url, payload: {} });
  assert.notEqual(empty.statusCode, 200);
  assert.equal(calls.length, 0);
  const missing = await app.inject({
    method: "POST",
    url: "/accounts/account-1/messages/99/flags",
    payload: { seen: true }
  });
  assert.equal(missing.statusCode, 404);
});

test("keeps the stored copy when the server rejects the change", async () => {
  const { app } = await setup(true);
  const response = await app.inject({
    method: "POST",
    url,
    payload: { flagged: true }
  });
  assert.equal(response.statusCode, 500);
  const list = await app.inject({ method: "GET", url: "/accounts/account-1/messages" });
  assert.equal(list.json()[0].flagged, false);
});
