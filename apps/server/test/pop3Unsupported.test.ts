import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import type { MailAccount } from "../src/domain/types.js";
import { registerRoutes } from "../src/api/routes.js";
import type { ImapReceiver } from "../src/mail/ImapReceiver.js";
import { Pop3Receiver, pop3UnsupportedMessage } from "../src/mail/Pop3Receiver.js";
import type { PushNotifier } from "../src/notifications/PushNotifier.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";
import { MailSyncWorker } from "../src/workers/MailSyncWorker.js";

test("adding a POP3 account is rejected with a clear message", async () => {
  const accounts = new InMemoryAccountRepository();
  const pop3 = new Pop3Receiver();
  let starts = 0;
  const app = Fastify();
  await registerRoutes(app, {
    accounts,
    sender: {} as never,
    validateAccount: (account) => pop3.testConnection(account),
    fetchMessageContent: async () => {
      throw new Error("unused");
    },
    startAccountSync: async () => {
      starts += 1;
    },
    resumeAccountSync: async () => undefined,
    stopAccountSync: async () => undefined
  });

  const response = await app.inject({
    method: "POST",
    url: "/accounts",
    payload: {
      providerId: "daum",
      emailAddress: "user@example.com",
      authMode: "password",
      incomingProtocol: "pop3",
      secret: "password"
    }
  });

  assert.equal(response.statusCode, 400);
  assert.equal(response.json().message, pop3UnsupportedMessage);
  assert.equal((await accounts.listActiveAccounts()).length, 0);
  assert.equal(starts, 0);
});

test("a stored POP3 account is never reported as synced", async () => {
  const now = new Date();
  const accounts = new InMemoryAccountRepository();
  const account: MailAccount = {
    id: "pop3-account",
    userId: "demo-user",
    providerId: "daum",
    emailAddress: "user@example.com",
    authMode: "password",
    incomingProtocol: "pop3",
    encryptedSecretRef: "password",
    createdAt: now,
    updatedAt: now
  };
  await accounts.addAccount(account);
  const worker = new MailSyncWorker(
    accounts,
    {} as ImapReceiver,
    new Pop3Receiver(),
    {} as PushNotifier,
    { mailbox: "INBOX", pop3PollIntervalMs: 5, imapReconnectBaseDelayMs: 1, imapReconnectMaxDelayMs: 1 }
  );

  try {
    await worker.startAccount(account);
    assert.equal(account.syncStatus, "error");
    assert.equal(account.syncError, pop3UnsupportedMessage);
    assert.equal(account.lastSyncedAt, undefined);
  } finally {
    await worker.stop();
  }
});
