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

function storedMessage(accountId: string, uid: string): IncomingMessageSummary {
  return {
    accountId,
    providerMessageId: uid,
    mailbox: "INBOX",
    from: "a@example.com",
    subject: `message ${uid}`,
    receivedAt: new Date(),
    hasAttachments: false
  };
}

function recordingImap(result: { uidValidity: string; highestUid?: number }) {
  const calls: Array<{ limit: unknown; cursor: unknown }> = [];
  const imap = {
    watch: async () => async () => undefined,
    fetchLatestBatches: async (
      _account: MailAccount,
      _mailbox: string,
      limit: number | "all",
      _onBatch: unknown,
      cursor?: unknown
    ) => {
      calls.push({ limit, cursor });
      return result;
    }
  };
  return { calls, imap };
}

test("a resync continues after the last completed sync", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = { ...account(), syncedUid: 41, syncedUidValidity: "7" };
  await repository.addAccount(mailAccount);
  // The IDLE watcher saved UID 51 while 42-50 were never checked.
  await repository.saveIncomingMessage(storedMessage(mailAccount.id, "51"));
  const { calls, imap } = recordingImap({ uidValidity: "7", highestUid: 75 });
  const syncWorker = worker(repository, imap);

  try {
    await syncWorker.syncAccount(mailAccount);
    assert.deepEqual(calls, [{ limit: 25, cursor: { uid: 41, uidValidity: "7" } }]);
    assert.equal(mailAccount.syncedUid, 75);
    assert.equal(mailAccount.syncedUidValidity, "7");
  } finally {
    await syncWorker.stop();
  }
});

test("accounts without a stored cursor continue after their newest saved UID", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  await repository.saveIncomingMessage(storedMessage(mailAccount.id, "40"));
  await repository.saveIncomingMessage(storedMessage(mailAccount.id, "41"));
  await repository.saveIncomingMessage(storedMessage("other-account", "900"));
  const { calls, imap } = recordingImap({ uidValidity: "7", highestUid: 41 });
  const syncWorker = worker(repository, imap);

  try {
    await syncWorker.syncAccount(mailAccount);
    assert.deepEqual(calls, [{ limit: 25, cursor: { uid: 41 } }]);
  } finally {
    await syncWorker.stop();
  }
});

test("the first import keeps the chosen limit and records the cursor", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  mailAccount.lastSyncedAt = undefined;
  mailAccount.initialSync = { includePreviousMessages: true, limit: 500 };
  await repository.addAccount(mailAccount);
  const { calls, imap } = recordingImap({ uidValidity: "7", highestUid: 1200 });
  const syncWorker = worker(repository, imap);

  try {
    await syncWorker.syncAccount(mailAccount);
    assert.deepEqual(calls, [{ limit: 500, cursor: undefined }]);
    assert.equal(mailAccount.syncedUid, 1200);
  } finally {
    await syncWorker.stop();
  }
});

test("skipping previous mail sets a baseline so later syncs import only new mail", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  mailAccount.lastSyncedAt = undefined;
  mailAccount.initialSync = { includePreviousMessages: false, limit: 100 };
  await repository.addAccount(mailAccount);
  const { calls, imap } = recordingImap({ uidValidity: "7", highestUid: 90 });
  const syncWorker = worker(repository, imap);

  try {
    await syncWorker.syncAccount(mailAccount);
    await syncWorker.syncAccount(mailAccount);
    assert.deepEqual(calls, [
      { limit: 0, cursor: undefined },
      { limit: 25, cursor: { uid: 90, uidValidity: "7" } }
    ]);
  } finally {
    await syncWorker.stop();
  }
});

test("a failed sync does not advance the cursor", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = { ...account(), syncedUid: 41, syncedUidValidity: "7" };
  await repository.addAccount(mailAccount);
  const imap = {
    watch: async () => async () => undefined,
    fetchLatestBatches: async () => {
      throw new Error("Connection closed");
    }
  };
  const syncWorker = worker(repository, imap);

  try {
    await syncWorker.syncAccount(mailAccount).catch(() => undefined);
    assert.equal(mailAccount.syncedUid, 41);
  } finally {
    await syncWorker.stop();
  }
});

test("an IDLE reconnect syncs the mail that arrived while disconnected", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  let disconnect: ((error: Error) => void) | undefined;
  let syncs = 0;
  const imap = {
    watch: async (
      _account: MailAccount,
      _mailbox: string,
      _onMessage: unknown,
      onDisconnect: (error: Error) => void
    ) => {
      disconnect = onDisconnect;
      return async () => undefined;
    },
    fetchLatestBatches: async () => {
      syncs += 1;
    }
  };
  const syncWorker = worker(repository, imap);

  try {
    await syncWorker.startAccount(mailAccount);
    assert.equal(syncs, 1);

    disconnect!(new Error("IMAP connection closed."));
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.equal(syncs, 2);
  } finally {
    await syncWorker.stop();
  }
});

test("a reconnect after a failed first watch still catches up", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  let watchCalls = 0;
  let syncs = 0;
  const imap = {
    watch: async () => {
      watchCalls += 1;
      if (watchCalls === 1) throw new Error("Connection refused");
      return async () => undefined;
    },
    fetchLatestBatches: async () => {
      syncs += 1;
      // The server is still down for the initial sync too.
      if (syncs === 1) throw new Error("Connection refused");
      return { uidValidity: "7", highestUid: 41 };
    }
  };
  const syncWorker = worker(repository, imap);

  try {
    await syncWorker.startAccount(mailAccount);
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.equal(watchCalls, 2);
    assert.equal(syncs, 2);
  } finally {
    await syncWorker.stop();
  }
});

test("a reconnect during a running import queues another sync", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = account();
  await repository.addAccount(mailAccount);
  let disconnect: ((error: Error) => void) | undefined;
  let releaseImport!: () => void;
  const runningImport = new Promise<void>((resolve) => {
    releaseImport = resolve;
  });
  let syncs = 0;
  const imap = {
    watch: async (
      _account: MailAccount,
      _mailbox: string,
      _onMessage: unknown,
      onDisconnect: (error: Error) => void
    ) => {
      disconnect = onDisconnect;
      return async () => undefined;
    },
    fetchLatestBatches: async () => {
      syncs += 1;
      if (syncs === 1) await runningImport;
      return { uidValidity: "7", highestUid: 41 };
    }
  };
  const syncWorker = worker(repository, imap);

  try {
    const start = syncWorker.startAccount(mailAccount);
    await new Promise((resolve) => setTimeout(resolve, 5));
    disconnect!(new Error("IMAP connection closed."));
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(syncs, 1);

    releaseImport();
    await start;
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(syncs, 2);
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

function customAccount(supportsIdle?: boolean): MailAccount {
  return {
    ...account(),
    id: "custom-account",
    providerId: "custom",
    connectionOverride: {
      incoming: { host: "imap.example.com", port: 993, secure: true, supportsIdle }
    }
  };
}

test("polls an IMAP server without IDLE instead of reconnecting forever", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = customAccount();
  await repository.addAccount(mailAccount);
  let watchCalls = 0;
  let syncs = 0;
  const imap = {
    watch: async () => {
      watchCalls += 1;
      return async () => undefined;
    },
    fetchLatestBatches: async () => {
      syncs += 1;
    }
  };
  const syncWorker = new MailSyncWorker(
    repository,
    imap as unknown as ImapReceiver,
    {} as Pop3Receiver,
    {} as PushNotifier,
    { mailbox: "INBOX", pop3PollIntervalMs: 5, imapReconnectBaseDelayMs: 1, imapReconnectMaxDelayMs: 1 }
  );

  try {
    await syncWorker.startAccount(mailAccount);
    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.equal(watchCalls, 0);
    assert.ok(syncs > 2, `expected repeated polls, got ${syncs}`);

    // resume leaves the running poll alone.
    const before = syncs;
    await syncWorker.resumeAccount(mailAccount);
    assert.ok(syncs - before <= 1);
  } finally {
    await syncWorker.stop();
  }
});

test("stops polling once the server rejects the credentials", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = customAccount();
  await repository.addAccount(mailAccount);
  let syncs = 0;
  const imap = {
    watch: async () => async () => undefined,
    fetchLatestBatches: async () => {
      syncs += 1;
      if (syncs >= 2) throw authenticationFailure("Authentication failed.");
    }
  };
  const syncWorker = new MailSyncWorker(
    repository,
    imap as unknown as ImapReceiver,
    {} as Pop3Receiver,
    {} as PushNotifier,
    { mailbox: "INBOX", pop3PollIntervalMs: 5, imapReconnectBaseDelayMs: 1, imapReconnectMaxDelayMs: 1 }
  );

  try {
    await syncWorker.startAccount(mailAccount);
    await new Promise((resolve) => setTimeout(resolve, 60));
    assert.equal(syncs, 2);
    assert.equal(mailAccount.syncErrorCode, "authentication");
  } finally {
    await syncWorker.stop();
  }
});

test("a custom server that declares IDLE support is watched", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = customAccount(true);
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
    await syncWorker.startAccount(mailAccount);
    assert.equal(watchCalls, 1);
  } finally {
    await syncWorker.stop();
  }
});

test("polled IMAP mail notifies only after the first import", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = customAccount();
  mailAccount.lastSyncedAt = undefined;
  await repository.addAccount(mailAccount);
  await repository.savePushTarget({ userId: "demo-user", platform: "macos", deviceToken: "token" });
  let fetches = 0;
  const notified: string[] = [];
  const imap = {
    watch: async () => async () => undefined,
    fetchLatestBatches: async (
      _account: MailAccount,
      _mailbox: string,
      _limit: unknown,
      onBatch: (messages: IncomingMessageSummary[]) => Promise<void>
    ) => {
      fetches += 1;
      await onBatch([{
        accountId: mailAccount.id,
        providerMessageId: String(fetches),
        mailbox: "INBOX",
        from: "a@example.com",
        subject: `message ${fetches}`,
        receivedAt: new Date(),
        hasAttachments: false
      }]);
    }
  };
  const syncWorker = new MailSyncWorker(
    repository,
    imap as unknown as ImapReceiver,
    {} as Pop3Receiver,
    {
      notifyNewMessage: async (_targets, message) => {
        notified.push(message.providerMessageId);
      }
    },
    { mailbox: "INBOX", pop3PollIntervalMs: 60_000, imapReconnectBaseDelayMs: 1, imapReconnectMaxDelayMs: 1 }
  );

  try {
    await syncWorker.syncAccount(mailAccount);
    await syncWorker.syncAccount(mailAccount);
    assert.deepEqual(notified, ["2"]);
  } finally {
    await syncWorker.stop();
  }
});

test("an account stopped during its first sync starts no polling", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = customAccount();
  await repository.addAccount(mailAccount);
  let release!: () => void;
  const firstSync = new Promise<void>((resolve) => {
    release = resolve;
  });
  let fetches = 0;
  const imap = {
    watch: async () => async () => undefined,
    fetchLatestBatches: async () => {
      fetches += 1;
      if (fetches === 1) await firstSync;
    }
  };
  const syncWorker = new MailSyncWorker(
    repository,
    imap as unknown as ImapReceiver,
    {} as Pop3Receiver,
    {} as PushNotifier,
    { mailbox: "INBOX", pop3PollIntervalMs: 5, imapReconnectBaseDelayMs: 1, imapReconnectMaxDelayMs: 1 }
  );

  try {
    const start = syncWorker.startAccount(mailAccount);
    await new Promise((resolve) => setTimeout(resolve, 5));
    await syncWorker.stopAccount(mailAccount.id);
    release();
    await start;
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.equal(fetches, 1);
  } finally {
    await syncWorker.stop();
  }
});

test("polling keeps the opt-out from importing previous mail", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = customAccount();
  mailAccount.lastSyncedAt = undefined;
  mailAccount.initialSync = { includePreviousMessages: false, limit: 100 };
  mailAccount.createdAt = new Date("2026-11-22T00:00:00Z");
  await repository.addAccount(mailAccount);
  const message = (uid: string, sentAt: string, arrivedAt: string): IncomingMessageSummary => ({
    accountId: mailAccount.id,
    providerMessageId: uid,
    mailbox: "INBOX",
    from: "a@example.com",
    subject: uid,
    receivedAt: new Date(sentAt),
    arrivedAt: new Date(arrivedAt),
    hasAttachments: false
  });
  const imap = {
    watch: async () => async () => undefined,
    fetchLatestBatches: async (
      _account: MailAccount,
      _mailbox: string,
      _limit: unknown,
      onBatch: (messages: IncomingMessageSummary[]) => Promise<void>
    ) => {
      await onBatch([
        message("old", "2026-11-01T00:00:00Z", "2026-11-01T00:00:05Z"),
        // Sent before the account was added but delivered after it.
        message("delayed", "2026-11-21T23:50:00Z", "2026-11-22T00:30:00Z"),
        message("new", "2026-11-22T01:00:00Z", "2026-11-22T01:00:05Z")
      ]);
    }
  };
  const syncWorker = new MailSyncWorker(
    repository,
    imap as unknown as ImapReceiver,
    {} as Pop3Receiver,
    { notifyNewMessage: async () => undefined },
    { mailbox: "INBOX", pop3PollIntervalMs: 60_000, imapReconnectBaseDelayMs: 1, imapReconnectMaxDelayMs: 1 }
  );

  try {
    await syncWorker.syncAccount(mailAccount);
    await syncWorker.syncAccount(mailAccount);
    const saved = (await repository.listInbox("demo-user")).map((item) => item.subject);
    assert.deepEqual(saved, ["new", "delayed"]);
  } finally {
    await syncWorker.stop();
  }
});

test("stopping unknown accounts keeps no per-account state", async () => {
  const repository = new InMemoryAccountRepository();
  const syncWorker = worker(repository, {});
  for (let index = 0; index < 100; index += 1) {
    await syncWorker.stopAccount(`unknown-${index}`);
  }
  const pending = (syncWorker as unknown as { pendingStarts: Map<string, object> }).pendingStarts;
  assert.equal(pending.size, 0);
  await syncWorker.stop();
});

test("history first reached by a later poll sends no notification", async () => {
  const repository = new InMemoryAccountRepository();
  const mailAccount = customAccount();
  mailAccount.lastSyncedAt = undefined;
  mailAccount.initialSync = { includePreviousMessages: true, limit: 1 };
  mailAccount.createdAt = new Date("2026-11-22T00:00:00Z");
  await repository.addAccount(mailAccount);
  await repository.savePushTarget({ userId: "demo-user", platform: "macos", deviceToken: "token" });
  const message = (uid: string, arrivedAt: string): IncomingMessageSummary => ({
    accountId: mailAccount.id,
    providerMessageId: uid,
    mailbox: "INBOX",
    from: "a@example.com",
    subject: uid,
    receivedAt: new Date(arrivedAt),
    arrivedAt: new Date(arrivedAt),
    hasAttachments: false
  });
  let fetches = 0;
  const notified: string[] = [];
  const imap = {
    watch: async () => async () => undefined,
    fetchLatestBatches: async (
      _account: MailAccount,
      _mailbox: string,
      _limit: unknown,
      onBatch: (messages: IncomingMessageSummary[]) => Promise<void>
    ) => {
      fetches += 1;
      await onBatch(fetches === 1
        ? [message("3", "2026-11-21T10:00:00Z")]
        : [
            message("1", "2026-11-20T10:00:00Z"),
            message("2", "2026-11-21T09:00:00Z"),
            message("3", "2026-11-21T10:00:00Z"),
            message("4", "2026-11-22T01:00:00Z")
          ]);
    }
  };
  const syncWorker = new MailSyncWorker(
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

  try {
    await syncWorker.syncAccount(mailAccount);
    await syncWorker.syncAccount(mailAccount);
    assert.deepEqual(notified, ["4"]);
  } finally {
    await syncWorker.stop();
  }
});
