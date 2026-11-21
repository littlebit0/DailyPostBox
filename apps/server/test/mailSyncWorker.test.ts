import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LocalFileAccountRepository } from "../src/workers/LocalFileAccountRepository.js";
import type { IncomingMessageSummary, MailAccount } from "../src/domain/types.js";
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
      imapReconnectMaxDelayMs: 1,
      backfillYieldMs: 0
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

test("keeps the authentication error when the initial import is skipped", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  mailAccount.lastSyncedAt = undefined;
  mailAccount.initialSync = { includePreviousMessages: false, limit: 100 };
  await repository.addAccount(mailAccount);
  const imap = {
    watch: async () => {
      throw authenticationFailure("Authentication failed.");
    },
    fetchLatestBatches: async () => undefined
  };
  const syncWorker = worker(repository, imap);

  try {
    await syncWorker.startAccount(mailAccount);
    assert.equal(mailAccount.syncStatus, "error");
    assert.equal(mailAccount.syncErrorCode, "authentication");
  } finally {
    await syncWorker.stop();
  }
});

test("a superseded sync cannot overwrite the restarted sync's status", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  let fetchCalls = 0;
  let rejectOldFetch: (error: Error) => void = () => undefined;
  const imap = {
    watch: async () => async () => undefined,
    fetchLatestBatches: () => {
      fetchCalls += 1;
      if (fetchCalls === 1) {
        return new Promise<void>((_resolve, reject) => {
          rejectOldFetch = reject;
        });
      }
      return Promise.resolve();
    }
  };
  const syncWorker = worker(repository, imap);

  try {
    const oldStart = syncWorker.startAccount(mailAccount);
    await new Promise((resolve) => setTimeout(resolve, 5));

    // Reconnect: stop with the old credentials, then start again.
    await syncWorker.stopAccount(mailAccount.id);
    await syncWorker.startAccount(mailAccount);
    assert.equal(fetchCalls, 2);
    assert.equal(mailAccount.syncStatus, "idle");

    rejectOldFetch(authenticationFailure("Authentication failed."));
    await oldStart;
    assert.equal(mailAccount.syncStatus, "idle");
    assert.equal(mailAccount.syncErrorCode, undefined);
  } finally {
    await syncWorker.stop();
  }
});

test("resume starts a stopped watcher once and leaves a running one alone", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  let watchCalls = 0;
  const imap = {
    watch: async () => {
      watchCalls += 1;
      return async () => undefined;
    },
    fetchLatestBatches: async () => undefined
  };
  const syncWorker = worker(repository, imap);

  try {
    await syncWorker.resumeAccount(mailAccount);
    await syncWorker.resumeAccount(mailAccount);
    assert.equal(watchCalls, 1);
  } finally {
    await syncWorker.stop();
  }
});

test("a failing push does not disturb mail handling", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  await repository.savePushTarget({ userId: "demo-user", platform: "macos", deviceToken: "token" });
  let deliver: ((message: IncomingMessageSummary) => Promise<void>) | undefined;
  const imap = {
    watch: async (
      _account: MailAccount,
      _mailbox: string,
      onMessage: (message: IncomingMessageSummary) => Promise<void>
    ) => {
      deliver = onMessage;
      return async () => undefined;
    },
    fetchLatestBatches: async () => undefined
  };
  const syncWorker = new MailSyncWorker(
    repository,
    imap as unknown as ImapReceiver,
    {} as Pop3Receiver,
    { notifyNewMessage: async () => { throw new Error("ECONNRESET"); } },
    { mailbox: "INBOX", pop3PollIntervalMs: 60_000, imapReconnectBaseDelayMs: 1, imapReconnectMaxDelayMs: 1 }
  );

  try {
    await syncWorker.startAccount(mailAccount);
    await deliver!({
      accountId: mailAccount.id,
      providerMessageId: "7",
      mailbox: "INBOX",
      from: "a@example.com",
      subject: "hi",
      receivedAt: new Date(),
      hasAttachments: false
    });
    assert.equal((await repository.listInbox("demo-user")).length, 1);
  } finally {
    await syncWorker.stop();
  }
});

test("backfills thread metadata for stored messages once, in bounded batches", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  const stored = (uid: number): IncomingMessageSummary => ({
    accountId: mailAccount.id,
    providerMessageId: String(uid),
    mailbox: "INBOX",
    from: "a@example.com",
    subject: "old",
    receivedAt: new Date(uid * 1000),
    hasAttachments: false
  });
  for (let uid = 1; uid <= 120; uid += 1) {
    await repository.saveIncomingMessage(stored(uid));
  }
  const requests: number[][] = [];
  const imap = {
    fetchLatestBatches: async () => undefined,
    fetchSummariesByUid: async (_a: MailAccount, _m: string, uids: number[]) => {
      requests.push(uids);
      // uid 1 is gone from the server; the rest carry a Message-ID.
      return uids.filter((uid) => uid !== 1).map((uid) => ({
        ...stored(uid),
        messageId: `<m${uid}@example.com>`,
        references: ["<root@example.com>"]
      }));
    }
  };
  const syncWorker = worker(repository, imap);

  await syncWorker.syncAccount(mailAccount);
  await syncWorker.backfillSettled(mailAccount.id);
  assert.deepEqual(requests.map((r) => r.length), [50, 50, 20]);
  const inbox = await repository.listInbox(mailAccount.userId);
  assert.equal(inbox.find((m) => m.providerMessageId === "2")?.messageId, "<m2@example.com>");
  assert.deepEqual(inbox.find((m) => m.providerMessageId === "1")?.references, []);

  await syncWorker.syncAccount(mailAccount);
  await syncWorker.backfillSettled(mailAccount.id);
  assert.equal(requests.length, 3);
});

test("backfill drains 4,000 stored messages across batches without refetching", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  const total = 4000;
  for (let uid = 1; uid <= total; uid += 1) {
    await repository.saveIncomingMessage({
      accountId: mailAccount.id,
      providerMessageId: String(uid),
      mailbox: "INBOX",
      from: "a@example.com",
      subject: "old",
      receivedAt: new Date(uid * 1000),
      hasAttachments: false
    });
  }
  const seen: number[] = [];
  const imap = {
    fetchLatestBatches: async () => undefined,
    fetchSummariesByUid: async (_a: MailAccount, _m: string, uids: number[]) => {
      assert.ok(uids.length <= 50);
      seen.push(...uids);
      return uids.map((uid) => ({
        accountId: mailAccount.id,
        providerMessageId: String(uid),
        mailbox: "INBOX",
        from: "a@example.com",
        subject: "old",
        receivedAt: new Date(uid * 1000),
        hasAttachments: false,
        messageId: `<m${uid}@example.com>`,
        references: []
      }));
    }
  };
  const syncWorker = worker(repository, imap);

  await syncWorker.syncAccount(mailAccount);
  await syncWorker.backfillSettled(mailAccount.id);
  assert.equal(seen.length, total);
  assert.equal(new Set(seen).size, total);
  const inbox = await repository.listInbox(mailAccount.userId);
  assert.ok(inbox.every((m) => m.references !== undefined));

  await syncWorker.syncAccount(mailAccount);
  await syncWorker.backfillSettled(mailAccount.id);
  assert.equal(seen.length, total);
});

test("backfill stops when the account is removed", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  for (let uid = 1; uid <= 200; uid += 1) {
    await repository.saveIncomingMessage({
      accountId: mailAccount.id,
      providerMessageId: String(uid),
      mailbox: "INBOX",
      from: "a@example.com",
      subject: "old",
      receivedAt: new Date(uid * 1000),
      hasAttachments: false
    });
  }
  let calls = 0;
  let syncWorker: MailSyncWorker;
  const imap = {
    fetchLatestBatches: async () => undefined,
    fetchSummariesByUid: async () => {
      calls += 1;
      await syncWorker.stopAccount(mailAccount.id);
      return [];
    }
  };
  syncWorker = worker(repository, imap);
  await syncWorker.syncAccount(mailAccount);
  await syncWorker.backfillSettled(mailAccount.id);
  assert.equal(calls, 1);
});

test("backfill persists each 50-message batch with bounded file writes", async () => {
  const repository = new LocalFileAccountRepository(join(await mkdtemp(join(tmpdir(), "backfill-")), "state.json"));
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  const total = 200;
  for (let uid = 1; uid <= total; uid += 1) {
    await repository.saveIncomingMessage({
      accountId: mailAccount.id,
      providerMessageId: String(uid),
      mailbox: "INBOX",
      from: "a@example.com",
      subject: "old",
      receivedAt: new Date(uid * 1000),
      hasAttachments: false
    });
  }
  const imap = {
    fetchLatestBatches: async () => undefined,
    fetchSummariesByUid: async (_a: MailAccount, _m: string, uids: number[]) =>
      uids.map((uid) => ({
        accountId: mailAccount.id,
        providerMessageId: String(uid),
        mailbox: "INBOX",
        from: "a@example.com",
        subject: "old",
        receivedAt: new Date(uid * 1000),
        hasAttachments: false,
        messageId: `<m${uid}@example.com>`,
        references: []
      }))
  };
  const internals = repository as unknown as { flush: () => Promise<void> };
  const originalFlush = internals.flush.bind(repository);
  let flushes = 0;
  internals.flush = () => {
    flushes += 1;
    return originalFlush();
  };

  const syncWorker = worker(repository as unknown as InMemoryAccountRepository, imap);
  await syncWorker.syncAccount(mailAccount);
  await syncWorker.backfillSettled(mailAccount.id);

  const inbox = await repository.listInbox(mailAccount.userId);
  assert.ok(inbox.every((m) => m.messageId !== undefined));
  // 4 batches of 50; per-message writes would be 200.
  assert.ok(flushes <= 8, `expected bounded writes, got ${flushes}`);
});

test("stopAccount waits for the in-flight backfill batch save and nothing is written after", async () => {
  const mailAccount = account();
  const inner = new InMemoryAccountRepository();
  await inner.addAccount(mailAccount);
  for (let uid = 1; uid <= 3; uid += 1) {
    await inner.saveIncomingMessage({
      accountId: mailAccount.id, providerMessageId: String(uid), mailbox: "INBOX",
      from: "a@example.com", subject: "old", receivedAt: new Date(uid), hasAttachments: false
    });
  }
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  let saveStarted!: () => void;
  const started = new Promise<void>((resolve) => { saveStarted = resolve; });
  let saves = 0;
  const repository = Object.create(inner) as InMemoryAccountRepository;
  repository.saveIncomingMessage = async (message) => {
    if (message.messageId !== undefined) {
      saves += 1;
      saveStarted();
      await gate;
    }
    return inner.saveIncomingMessage(message);
  };
  const imap = {
    fetchLatestBatches: async () => undefined,
    fetchSummariesByUid: async (_a: MailAccount, _m: string, uids: number[]) =>
      uids.map((uid) => ({
        accountId: mailAccount.id, providerMessageId: String(uid), mailbox: "INBOX",
        from: "a@example.com", subject: "old", receivedAt: new Date(uid),
        hasAttachments: false, messageId: `<m${uid}@example.com>`, references: []
      }))
  };
  const syncWorker = worker(repository, imap);
  await syncWorker.syncAccount(mailAccount);
  await started;

  let stopped = false;
  const stopping = syncWorker.stopAccount(mailAccount.id).then(() => { stopped = true; });
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(stopped, false, "stopAccount must wait for the pending save");
  release();
  await stopping;
  await inner.deleteAccount(mailAccount.id);
  await syncWorker.backfillSettled(mailAccount.id);
  assert.equal(saves, 3);
  assert.equal((await inner.listInbox(mailAccount.userId)).length, 0);
});

test("backfill exposes threadBackfill while running and clears it on completion", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  await repository.saveIncomingMessage({
    accountId: mailAccount.id, providerMessageId: "1", mailbox: "INBOX",
    from: "a@example.com", subject: "old", receivedAt: new Date(1), hasAttachments: false
  });
  let during: string | undefined;
  const imap = {
    fetchLatestBatches: async () => undefined,
    fetchSummariesByUid: async (_a: MailAccount, _m: string, uids: number[]) => {
      during = (await repository.getAccount(mailAccount.id))?.threadBackfill;
      return uids.map((uid) => ({
        accountId: mailAccount.id, providerMessageId: String(uid), mailbox: "INBOX",
        from: "a@example.com", subject: "old", receivedAt: new Date(uid),
        hasAttachments: false, messageId: `<m${uid}@example.com>`, references: []
      }));
    }
  };
  const syncWorker = worker(repository, imap);
  await syncWorker.syncAccount(mailAccount);
  await syncWorker.backfillSettled(mailAccount.id);
  assert.equal(during, "running");
  assert.equal((await repository.getAccount(mailAccount.id))?.threadBackfill, undefined);
});

test("backfill target grouping stays linear for 60,000 stored messages", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  for (let uid = 1; uid <= 60_000; uid += 1) {
    await repository.saveIncomingMessage({
      accountId: mailAccount.id, providerMessageId: String(uid), mailbox: "INBOX",
      from: "a@example.com", subject: "old", receivedAt: new Date(uid), hasAttachments: false
    });
  }
  const imap = {
    fetchLatestBatches: async () => undefined,
    fetchSummariesByUid: async () => { throw new Error("stop"); }
  };
  const syncWorker = worker(repository, imap);
  const startedAt = Date.now();
  await syncWorker.syncAccount(mailAccount);
  await syncWorker.backfillSettled(mailAccount.id);
  assert.ok(Date.now() - startedAt < 3000, "grouping 60,000 targets should be fast");
});
