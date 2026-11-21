import assert from "node:assert/strict";
import test from "node:test";
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
