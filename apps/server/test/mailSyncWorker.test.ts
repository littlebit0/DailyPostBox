import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { IncomingMessageSummary, MailAccount } from "../src/domain/types.js";
import type { ImapReceiver } from "../src/mail/ImapReceiver.js";
import type { Pop3Receiver } from "../src/mail/Pop3Receiver.js";
import type { PushNotifier } from "../src/notifications/PushNotifier.js";
import { authenticationFailure } from "../src/mail/authenticationFailure.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";
import { LocalFileAccountRepository } from "../src/workers/LocalFileAccountRepository.js";
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

function worker(repository: InMemoryAccountRepository | LocalFileAccountRepository, imap: object) {
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

test("backfills categories for stored messages once, in bounded batches", async () => {
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
  for (let uid = 1; uid <= 520; uid += 1) {
    await repository.saveIncomingMessage(stored(uid));
  }
  const requests: number[][] = [];
  const imap = {
    fetchLatestBatches: async () => undefined,
    fetchSummariesByUid: async (_a: MailAccount, _m: string, uids: number[]) => {
      requests.push(uids);
      // uid 1 is gone from the server; even uids are newsletters.
      return uids.filter((uid) => uid !== 1).map((uid) => ({
        ...stored(uid),
        category: uid % 2 === 0 ? "newsletter" as const : "person" as const
      }));
    }
  };
  const syncWorker = worker(repository, imap);

  await syncWorker.syncAccount(mailAccount);
  assert.equal(requests.length, 10);
  assert.ok(requests.every((r) => r.length === 50));
  const byUid = async () => new Map(
    (await repository.listInbox(mailAccount.userId)).map((m) => [m.providerMessageId, m])
  );
  // Newest first: uids 21..520 are done, the oldest 20 wait for the next sync.
  assert.equal((await byUid()).get("100")?.category, "newsletter");
  assert.equal((await byUid()).get("101")?.category, "person");
  assert.equal((await byUid()).get("2")?.category, undefined);

  // Next sync handles the remaining 20 once, then nothing is refetched.
  await syncWorker.syncAccount(mailAccount);
  assert.equal((await byUid()).get("2")?.category, "newsletter");
  assert.equal((await byUid()).get("1")?.category, "person");
  assert.equal(requests.length, 11);
  assert.equal(requests[10].length, 20);
  await syncWorker.syncAccount(mailAccount);
  assert.equal(requests.length, 11);
});

test("category backfill writes the state file once per batch", async () => {
  const dir = await mkdtemp(join(tmpdir(), "backfill-"));
  const repository = new LocalFileAccountRepository(join(dir, "state.json"));
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
  for (let uid = 1; uid <= 100; uid += 1) {
    await repository.saveIncomingMessage(stored(uid));
  }
  const internals = repository as unknown as { flush: () => Promise<void> };
  const originalFlush = internals.flush.bind(repository);
  let flushes = 0;
  internals.flush = () => {
    flushes += 1;
    return originalFlush();
  };
  const imap = {
    fetchLatestBatches: async () => undefined,
    fetchSummariesByUid: async (_a: MailAccount, _m: string, uids: number[]) =>
      uids.map((uid) => ({ ...stored(uid), category: "newsletter" as const }))
  };

  await worker(repository, imap).syncAccount(mailAccount);
  // 2 batches of 50, plus a few sync status writes; per-message saves gave 100+.
  assert.ok(flushes <= 6, `flushes=${flushes}`);
});
