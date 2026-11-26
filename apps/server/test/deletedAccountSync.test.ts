import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { IncomingMessageSummary, MailAccount } from "../src/domain/types.js";
import type { ImapReceiver } from "../src/mail/ImapReceiver.js";
import type { Pop3Receiver } from "../src/mail/Pop3Receiver.js";
import type { PushNotifier } from "../src/notifications/PushNotifier.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";
import { LocalFileAccountRepository } from "../src/workers/LocalFileAccountRepository.js";
import { MailSyncWorker } from "../src/workers/MailSyncWorker.js";

function account(): MailAccount {
  const now = new Date();
  return {
    id: "account-1",
    userId: "demo-user",
    providerId: "naver",
    emailAddress: "user@example.com",
    authMode: "app-password",
    incomingProtocol: "imap",
    encryptedSecretRef: "secret",
    initialSync: { includePreviousMessages: true, limit: "all" },
    createdAt: now,
    updatedAt: now
  };
}

function message(uid: string): IncomingMessageSummary {
  return {
    accountId: "account-1",
    providerMessageId: uid,
    mailbox: "INBOX",
    from: "a@example.com",
    subject: "subject",
    receivedAt: new Date(),
    hasAttachments: false
  };
}

test("the file repository ignores mail for a deleted account", async () => {
  const directory = await mkdtemp(join(tmpdir(), "dailypostbox-"));
  const filePath = join(directory, "state.json");
  try {
    const repository = new LocalFileAccountRepository(filePath);
    await repository.addAccount(account());
    assert.equal(await repository.saveIncomingMessage(message("1")), true);
    await repository.deleteAccount("account-1");

    assert.equal(await repository.saveIncomingMessage(message("2")), false);
    const stored = JSON.parse(await readFile(filePath, "utf8")) as { messages: unknown[] };
    assert.deepEqual(stored.messages, []);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("deleting an account stops its running import", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  let batchesDelivered = 0;
  let releaseSecondBatch!: () => void;
  const secondBatch = new Promise<void>((resolve) => {
    releaseSecondBatch = resolve;
  });
  const imap = {
    watch: async () => async () => undefined,
    fetchLatestBatches: async (
      _account: MailAccount,
      _mailbox: string,
      _limit: unknown,
      onBatch: (messages: IncomingMessageSummary[]) => Promise<void>
    ) => {
      await onBatch([message("3")]);
      batchesDelivered += 1;
      await secondBatch;
      await onBatch([message("2")]);
      batchesDelivered += 1;
      await onBatch([message("1")]);
      batchesDelivered += 1;
    }
  };
  const worker = new MailSyncWorker(
    repository,
    imap as unknown as ImapReceiver,
    {} as Pop3Receiver,
    {} as PushNotifier,
    { mailbox: "INBOX", pop3PollIntervalMs: 60_000, imapReconnectBaseDelayMs: 1, imapReconnectMaxDelayMs: 1 }
  );

  const sync = worker.syncAccount(mailAccount);
  await new Promise((resolve) => setTimeout(resolve, 5));
  await worker.stopAccount(mailAccount.id);
  await repository.deleteAccount(mailAccount.id);
  releaseSecondBatch();
  await sync;

  assert.equal(batchesDelivered, 1);
  assert.equal((await repository.listInbox("demo-user")).length, 0);
  await worker.stop();
});
