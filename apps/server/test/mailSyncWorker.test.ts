import assert from "node:assert/strict";
import test from "node:test";
import type { MailAccount } from "../src/domain/types.js";
import type { ImapReceiver } from "../src/mail/ImapReceiver.js";
import type { Pop3Receiver } from "../src/mail/Pop3Receiver.js";
import type { PushNotifier } from "../src/notifications/PushNotifier.js";
import { authenticationFailure } from "../src/mail/authenticationFailure.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";
import { MailSyncWorker } from "../src/workers/MailSyncWorker.js";

function account(): MailAccount {
  const now = new Date();
  return {
    id: "naver-account",
    userId: "demo-user",
    providerId: "naver",
    emailAddress: "user@example.com",
    authMode: "app-password",
    incomingProtocol: "imap",
    encryptedSecretRef: "secret",
    lastSyncedAt: now,
    createdAt: now,
    updatedAt: now
  };
}

function worker(repository: InMemoryAccountRepository, imap: object) {
  return new MailSyncWorker(
    repository,
    imap as ImapReceiver,
    {} as Pop3Receiver,
    {} as PushNotifier,
    {
      mailbox: "INBOX",
      pop3PollIntervalMs: 60_000,
      imapReconnectBaseDelayMs: 1,
      imapReconnectMaxDelayMs: 1
    }
  );
}

test("stops IMAP reconnects after an authentication failure", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  let watchCalls = 0;
  const imap = {
    watch: async () => {
      watchCalls += 1;
      throw authenticationFailure("Authentication failed.");
    },
    fetchLatestBatches: async () => {
      throw authenticationFailure("Authentication failed.");
    }
  };
  const syncWorker = worker(repository, imap);

  try {
    await syncWorker.startAccount(mailAccount);
    await new Promise((resolve) => setTimeout(resolve, 30));

    assert.equal(watchCalls, 1);
    assert.equal(mailAccount.syncStatus, "error");
    assert.equal(mailAccount.syncErrorCode, "authentication");

    // A manual sync after the user fixes credentials starts watching again.
    await syncWorker.startAccount(mailAccount);
    assert.equal(watchCalls, 2);
  } finally {
    await syncWorker.stop();
  }
});

test("keeps reconnecting after a network failure", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  let watchCalls = 0;
  const imap = {
    watch: async () => {
      watchCalls += 1;
      throw new Error("Connection closed");
    },
    fetchLatestBatches: async () => undefined
  };
  const syncWorker = worker(repository, imap);

  await syncWorker.startAccount(mailAccount);
  await new Promise((resolve) => setTimeout(resolve, 30));
  await syncWorker.stop();

  assert.ok(watchCalls > 1);
  assert.equal(mailAccount.syncErrorCode, undefined);
});
