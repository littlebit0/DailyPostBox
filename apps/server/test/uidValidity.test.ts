import assert from "node:assert/strict";
import test from "node:test";
import type { IncomingMessageSummary, MailAccount } from "../src/domain/types.js";
import type { ImapReceiver } from "../src/mail/ImapReceiver.js";
import type { Pop3Receiver } from "../src/mail/Pop3Receiver.js";
import type { PushNotifier } from "../src/notifications/PushNotifier.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";
import { MailSyncWorker } from "../src/workers/MailSyncWorker.js";

function account(uidValidity?: string): MailAccount {
  const now = new Date();
  return {
    id: "account-1",
    userId: "demo-user",
    providerId: "naver",
    emailAddress: "user@example.com",
    authMode: "app-password",
    incomingProtocol: "imap",
    encryptedSecretRef: "secret",
    initialSync: { includePreviousMessages: true, limit: 100 },
    lastSyncedAt: now,
    uidValidity,
    createdAt: now,
    updatedAt: now
  };
}

function message(uid: string, subject: string): IncomingMessageSummary {
  return {
    accountId: "account-1",
    providerMessageId: uid,
    mailbox: "INBOX",
    from: "a@example.com",
    subject,
    receivedAt: new Date(),
    hasAttachments: false
  };
}

async function sync(stored: MailAccount, serverUidValidity: string) {
  const repository = new InMemoryAccountRepository();
  await repository.addAccount(stored);
  await repository.saveIncomingMessage(message("5", "old numbering"));
  const limits: unknown[] = [];
  const imap = {
    fetchLatestBatches: async (
      _account: MailAccount,
      _mailbox: string,
      limit: number | "all",
      onBatch: (messages: IncomingMessageSummary[]) => Promise<void>,
      _cursor: unknown,
      onMailboxOpened: (uidValidity: string) => Promise<number | "all" | undefined>
    ) => {
      // Like ImapReceiver: reconcile on the fetching connection first.
      limits.push((await onMailboxOpened(serverUidValidity)) ?? limit);
      await onBatch([message("1", "new numbering")]);
    }
  };
  const worker = new MailSyncWorker(
    repository,
    imap as unknown as ImapReceiver,
    {} as Pop3Receiver,
    {} as PushNotifier,
    { mailbox: "INBOX", pop3PollIntervalMs: 60_000, imapReconnectBaseDelayMs: 1, imapReconnectMaxDelayMs: 1 }
  );
  await worker.syncAccount(stored);
  await worker.stop();
  const subjects = (await repository.listInbox("demo-user")).map((item) => item.subject).sort();
  return { subjects, limits, uidValidity: stored.uidValidity };
}

test("a changed UIDVALIDITY drops old UIDs and imports again", async () => {
  const result = await sync(account("100"), "200");
  assert.deepEqual(result.subjects, ["new numbering"]);
  // The fresh import uses the account's initial import choice.
  assert.deepEqual(result.limits, [100]);
  assert.equal(result.uidValidity, "200");
});

test("an unchanged UIDVALIDITY keeps the stored mail", async () => {
  const result = await sync(account("100"), "100");
  assert.deepEqual(result.subjects, ["new numbering", "old numbering"]);
  assert.deepEqual(result.limits, [25]);
});

test("the first recorded UIDVALIDITY keeps existing mail", async () => {
  const result = await sync(account(undefined), "100");
  assert.deepEqual(result.subjects, ["new numbering", "old numbering"]);
  assert.equal(result.uidValidity, "100");
});

test("a connection retry after the reset keeps the initial import limit", async () => {
  const repository = new InMemoryAccountRepository();
  const stored = account("100");
  await repository.addAccount(stored);
  const limits: unknown[] = [];
  const imap = {
    fetchLatestBatches: async (
      _account: MailAccount,
      _mailbox: string,
      limit: number | "all",
      onBatch: (messages: IncomingMessageSummary[]) => Promise<void>,
      _cursor: unknown,
      onMailboxOpened: (uidValidity: string) => Promise<number | "all" | undefined>
    ) => {
      // Like ImapReceiver's retry: reconcile again on the new connection.
      limits.push((await onMailboxOpened("200")) ?? limit);
      limits.push((await onMailboxOpened("200")) ?? limit);
      await onBatch([message("1", "new numbering")]);
    }
  };
  const worker = new MailSyncWorker(
    repository,
    imap as unknown as ImapReceiver,
    {} as Pop3Receiver,
    {} as PushNotifier,
    { mailbox: "INBOX", pop3PollIntervalMs: 60_000, imapReconnectBaseDelayMs: 1, imapReconnectMaxDelayMs: 1 }
  );
  await worker.syncAccount(stored);
  await worker.stop();

  assert.deepEqual(limits, [100, 100]);
});

async function recover(stored: MailAccount, notified: string[]) {
  const repository = new InMemoryAccountRepository();
  await repository.addAccount(stored);
  await repository.savePushTarget({ userId: "demo-user", platform: "macos", deviceToken: "token" });
  const limits: unknown[] = [];
  const delivered = (uid: string, arrivedAt: string): IncomingMessageSummary => ({
    ...message(uid, uid),
    receivedAt: new Date(arrivedAt),
    arrivedAt: new Date(arrivedAt)
  });
  const imap = {
    watch: async () => async () => undefined,
    fetchLatestBatches: async (
      _account: MailAccount,
      _mailbox: string,
      limit: number | "all",
      onBatch: (messages: IncomingMessageSummary[]) => Promise<void>,
      _cursor: unknown,
      onMailboxOpened: (uidValidity: string) => Promise<number | "all" | undefined>
    ) => {
      // Reconciled twice, like a retried connection.
      limits.push((await onMailboxOpened("200")) ?? limit);
      limits.push((await onMailboxOpened("200")) ?? limit);
      await onBatch([
        delivered("1", "2026-11-01T00:00:00Z"),
        delivered("2", "2026-11-23T00:00:00Z")
      ]);
    }
  };
  const worker = new MailSyncWorker(
    repository,
    imap as unknown as ImapReceiver,
    {} as Pop3Receiver,
    {
      notifyNewMessage: async (_targets, item) => {
        notified.push(item.providerMessageId);
      }
    },
    { mailbox: "INBOX", pop3PollIntervalMs: 60_000, imapReconnectBaseDelayMs: 1, imapReconnectMaxDelayMs: 1 }
  );
  await worker.syncAccount(stored);
  await worker.stop();
  const subjects = (await repository.listInbox("demo-user")).map((item) => item.subject);
  return { limits, subjects };
}

test("an opted-out account gets back mail since it was added after a reset", async () => {
  const stored = account("100");
  stored.initialSync = { includePreviousMessages: false, limit: 100 };
  stored.createdAt = new Date("2026-11-22T00:00:00Z");

  const result = await recover(stored, []);

  assert.deepEqual(result.limits, ["all", "all"]);
  assert.deepEqual(result.subjects, ["2"]);
});

test("mail restored after a reset sends no notifications", async () => {
  const stored: MailAccount = {
    ...account("100"),
    providerId: "custom",
    connectionOverride: {
      incoming: { host: "imap.example.com", port: 993, secure: true }
    },
    createdAt: new Date("2026-11-22T00:00:00Z")
  };
  const notified: string[] = [];

  const result = await recover(stored, notified);

  assert.deepEqual(result.subjects.sort(), ["1", "2"]);
  assert.deepEqual(notified, []);
});
