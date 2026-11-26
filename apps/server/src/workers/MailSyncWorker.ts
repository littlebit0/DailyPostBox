import type { MailAccount, IncomingMessageSummary } from "../domain/types.js";
import type {
  ImapReceiver,
  ImapSyncCursor,
  ImapSyncResult
} from "../mail/ImapReceiver.js";
import type { Pop3Receiver } from "../mail/Pop3Receiver.js";
import type { PushNotifier } from "../notifications/PushNotifier.js";
import type { AccountRepository } from "./AccountRepository.js";
import { supportsImapIdle } from "../providers/resolveConnectionSettings.js";
import {
  applySyncFailure,
  isAuthenticationFailure
} from "../mail/authenticationFailure.js";

export interface MailSyncWorkerOptions {
  pop3PollIntervalMs: number;
  mailbox: string;
  imapReconnectBaseDelayMs: number;
  imapReconnectMaxDelayMs: number;
  /** Pause between thread-metadata backfill batches (default 250). */
  backfillYieldMs?: number;
}

export class MailSyncWorker {
  private static readonly backfillBatch = 50;
  private readonly stopHandlers = new Map<string, () => Promise<void>>();
  private readonly pollingTimers = new Map<string, NodeJS.Timeout>();
  // accountId -> running backfill; stopAccount/stop drop the token to cancel it.
  private readonly backfills = new Map<string, { token: object; done: Promise<void>; saving?: Promise<unknown> }>();
  private readonly syncPromises = new Map<string, Promise<void>>();
  // stopAccount drops the token so a sync still running with replaced
  // credentials cannot overwrite the status of the restarted sync.
  private readonly syncTokens = new Map<string, object>();
  // Held only while a start awaits its first sync; stopAccount removes it so
  // that start installs no polling timer for a stopped or deleted account.
  private readonly pendingStarts = new Map<string, object>();

  constructor(
    private readonly accounts: AccountRepository,
    private readonly imap: ImapReceiver,
    private readonly pop3: Pop3Receiver,
    private readonly push: PushNotifier,
    private readonly options: MailSyncWorkerOptions
  ) {}

  async start(): Promise<void> {
    const activeAccounts = await this.accounts.listActiveAccounts();
    await Promise.all(activeAccounts.map((account) => this.startAccount(account)));
  }

  async startAccount(account: MailAccount): Promise<void> {
    if (supportsImapIdle(account)) {
      if (!this.stopHandlers.has(account.id)) {
        await this.startImapAccount(account);
      }
      // The watcher stopped on rejected credentials; a sync would fail the
      // same way, or with a skipped import mark the account healthy.
      if (!this.stopHandlers.has(account.id) &&
        account.syncErrorCode === "authentication") {
        return;
      }
      await this.syncAccount(account).catch(() => undefined);
      return;
    }

    const start = {};
    this.pendingStarts.set(account.id, start);
    await this.syncAccount(account).catch(() => undefined);
    const stillWanted = this.pendingStarts.get(account.id) === start;
    if (stillWanted) this.pendingStarts.delete(account.id);
    if (!stillWanted || this.pollingTimers.has(account.id)) {
      return;
    }

    // POP3 is not implemented yet: its sync records the error status and
    // no polling timer is started.
    if (account.incomingProtocol === "imap") this.startImapPolling(account);
  }

  /** Starts watching or polling only when nothing is running for the account. */
  async resumeAccount(account: MailAccount): Promise<void> {
    const running = supportsImapIdle(account)
      ? this.stopHandlers.has(account.id)
      : this.pollingTimers.has(account.id);
    if (!running) await this.startAccount(account);
  }

  async syncAccount(account: MailAccount): Promise<void> {
    const activeSync = this.syncPromises.get(account.id);
    if (activeSync) return activeSync;

    const token = {};
    this.syncTokens.set(account.id, token);
    const sync = this.performSync(account, token).finally(() => {
      if (this.syncPromises.get(account.id) === sync) {
        this.syncPromises.delete(account.id);
      }
      if (this.syncTokens.get(account.id) === token) {
        this.syncTokens.delete(account.id);
      }
    });
    this.syncPromises.set(account.id, sync);
    return sync;
  }

  private async performSync(account: MailAccount, token: object): Promise<void> {
    const isCurrent = () => this.syncTokens.get(account.id) === token;
    const limit = this.initialSyncLimit(account);
    // Polled accounts have no IDLE watcher to notify them, so new mail found
    // after the first import is announced here. Older mail a later poll
    // reaches for the first time (beyond a small first import) is history:
    // only mail that reached the server after the account was added counts.
    const polled = account.lastSyncedAt !== undefined &&
      account.incomingProtocol === "imap" &&
      !supportsImapIdle(account);
    // Set once a changed UIDVALIDITY dropped the saved mail; the re-import
    // restores mail the user already had, so it announces nothing.
    let recovering = false;
    const notifies = (message: IncomingMessageSummary) =>
      !recovering && polled &&
      (message.arrivedAt ?? message.receivedAt) >= account.createdAt;
    // An account that opted out of previous mail keeps only mail that
    // reached the server after it was added. The server's arrival time is
    // used, not the sender's Date header, so delayed new mail is kept.
    const skipHistory = account.initialSync?.includePreviousMessages === false;
    const isWanted = (message: IncomingMessageSummary) =>
      !skipHistory || message.arrivedAt === undefined ||
      message.arrivedAt >= account.createdAt;
    const cursor = account.lastSyncedAt
      ? await this.syncCursor(account)
      : undefined;
    account.syncStatus = "syncing";
    account.syncError = undefined;
    account.syncErrorCode = undefined;
    await this.accounts.updateAccount(account);

    try {
      let result: ImapSyncResult | undefined;
      if (account.incomingProtocol === "imap") {
        // Runs even when history is skipped, to record the starting UID.
        result = await this.imap.fetchLatestBatches(
          account,
          this.options.mailbox,
          limit,
          async (messages) => {
            // Ends a superseded or deleted account's import between batches.
            if (!isCurrent()) throw new Error("Sync was cancelled.");
            await Promise.all(
              messages.filter(isWanted).map((message) =>
                this.handleIncoming(account, message, notifies(message))
              )
            );
          },
          cursor,
          async (uidValidity) => {
            if (await this.reconcileUidValidity(account, uidValidity)) {
              recovering = true;
            }
            // An opted-out account takes back everything since it was added
            // (isWanted drops older mail) instead of a zero-message import.
            // Derived on every call so a connection retry keeps it.
            return recovering && skipHistory ? "all" : this.initialSyncLimit(account);
          }
        );
      } else if (limit !== 0) {
        const messages = await this.pop3.fetchLatest(
          account,
          this.options.mailbox,
          limit
        );
        await Promise.all(
          messages.map((message) =>
            this.handleIncoming(account, message, false)
          )
        );
      }

      if (account.incomingProtocol === "imap" && isCurrent()) {
        this.startBackfill(account);
      }

      if (!isCurrent()) return;
      // Advanced only here: mail the IDLE watcher saved meanwhile must not
      // move the cursor past messages this sync has not checked.
      if (result?.highestUid !== undefined) {
        account.syncedUid = result.highestUid;
        account.syncedUidValidity = result.uidValidity;
      }
      account.syncStatus = "idle";
      account.lastSyncedAt = new Date();
      await this.accounts.updateAccount(account);
    } catch (error) {
      if (!isCurrent()) return;
      applySyncFailure(account, error);
      await this.accounts.updateAccount(account);
      throw error;
    }
  }

  async stop(): Promise<void> {
    const saving = [...this.backfills.values()].map((b) => b.saving);
    this.backfills.clear();
    await Promise.all(saving);
    for (const timer of this.pollingTimers.values()) clearInterval(timer);
    this.pollingTimers.clear();

    await Promise.all(
      [...this.stopHandlers.values()].map((stop) => stop().catch(() => undefined))
    );
    this.stopHandlers.clear();
  }

  async stopAccount(accountId: string): Promise<void> {
    this.pendingStarts.delete(accountId);
    this.syncPromises.delete(accountId);
    this.syncTokens.delete(accountId);
    const backfill = this.backfills.get(accountId);
    this.backfills.delete(accountId);
    // Wait for the batch save already issued so nothing is written after the caller deletes the account.
    await backfill?.saving?.catch(() => undefined);

    const timer = this.pollingTimers.get(accountId);
    if (timer) {
      clearInterval(timer);
      this.pollingTimers.delete(accountId);
    }

    const stop = this.stopHandlers.get(accountId);
    if (stop) {
      await stop().catch(() => undefined);
      this.stopHandlers.delete(accountId);
    }
  }

  private async startImapAccount(account: MailAccount): Promise<void> {
    let stopped = false;
    let reconnectDelay = this.options.imapReconnectBaseDelayMs;
    let reconnectTimer: NodeJS.Timeout | undefined;
    let activeStop: (() => Promise<void>) | undefined;

    const scheduleReconnect = (error: Error): void => {
      if (stopped || reconnectTimer) return;

      if (isAuthenticationFailure(error)) {
        // Repeated failed logins can lock the mailbox; wait for the user to
        // reconnect, sync or re-validate the account instead.
        stopped = true;
        void activeStop?.().catch(() => undefined);
        activeStop = undefined;
        if (this.stopHandlers.get(account.id) === stopWatching) {
          this.stopHandlers.delete(account.id);
        }
        console.warn("imap:watch-stopped-authentication", {
          accountId: account.id,
          error: error.message
        });
        applySyncFailure(account, error);
        void this.accounts.updateAccount(account).catch(() => undefined);
        return;
      }

      const delayMs = reconnectDelay;
      reconnectDelay = Math.min(
        reconnectDelay * 2,
        this.options.imapReconnectMaxDelayMs
      );

      console.warn("imap:watch-reconnect", {
        accountId: account.id,
        delayMs,
        error: error.message
      });

      void activeStop?.().catch(() => undefined);
      activeStop = undefined;
      reconnectTimer = setTimeout(() => {
        reconnectTimer = undefined;
        void connect();
      }, delayMs);
    };

    // startAccount syncs right after the first attempt; every later attempt
    // (a reconnect, even if the first one failed) must catch up itself.
    let firstAttempt = true;
    const connect = async (): Promise<void> => {
      if (stopped) return;
      const catchUp = !firstAttempt;
      firstAttempt = false;

      try {
        activeStop = await this.imap.watch?.(
          account,
          this.options.mailbox,
          async (message) => this.handleIncoming(account, message),
          scheduleReconnect
        );
        reconnectDelay = this.options.imapReconnectBaseDelayMs;
        if (account.incomingCapabilities) {
          await this.accounts.updateAccount(account).catch(() => undefined);
        }
        // Mail that arrived while disconnected raised no IDLE event. A sync
        // already running may have taken its UID snapshot before the outage,
        // so a fresh one starts after it instead of joining it.
        if (catchUp) {
          void (async () => {
            await this.syncPromises.get(account.id)?.catch(() => undefined);
            if (!stopped) await this.syncAccount(account);
          })().catch(() => undefined);
        }
      } catch (error) {
        scheduleReconnect(error instanceof Error ? error : new Error(String(error)));
      }
    };

    const stopWatching = async (): Promise<void> => {
      stopped = true;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      reconnectTimer = undefined;
      await activeStop?.().catch(() => undefined);
      activeStop = undefined;
    };
    this.stopHandlers.set(account.id, stopWatching);

    await connect();
  }

  // Servers without IDLE get new mail by periodic sync instead of a watcher
  // that would fail and reconnect forever.
  private startImapPolling(account: MailAccount): void {
    // Rejected credentials would fail every poll and can lock the mailbox.
    if (account.syncErrorCode === "authentication") return;
    const timer = setInterval(() => {
      if (account.syncErrorCode === "authentication") {
        clearInterval(timer);
        if (this.pollingTimers.get(account.id) === timer) {
          this.pollingTimers.delete(account.id);
        }
        return;
      }
      void this.syncAccount(account).catch(() => undefined);
    }, this.options.pop3PollIntervalMs);
    this.pollingTimers.set(account.id, timer);
  }

  private async handleIncoming(
    account: MailAccount,
    message: IncomingMessageSummary,
    notify = true
  ): Promise<void> {
    const isNew = await this.accounts.saveIncomingMessage(message);
    if (!notify || !isNew || account.notificationsEnabled === false) return;
    const targets = await this.accounts.listPushTargets(account.userId);
    // Push delivery must never block or tear down the IMAP watcher.
    void this.push.notifyNewMessage(targets, message).catch((error: unknown) => {
      console.warn("push:notify-failed", {
        accountId: account.id,
        error: error instanceof Error ? error.message : String(error)
      });
    });
  }

  /** Resolves when the account's background backfill (if any) has ended. */
  async backfillSettled(accountId: string): Promise<void> {
    await this.backfills.get(accountId)?.done;
  }

  // Messages stored before threading existed have no header metadata and the
  // 25-message sync never revisits them. Backfill runs in the background in
  // 50-message batches until none is left. Progress is the stored metadata
  // itself (a message the server no longer has gets `references: []`), so a
  // restart or the next sync simply continues with what is still missing.
  private startBackfill(account: MailAccount): void {
    if (this.backfills.has(account.id)) return;
    const token = {};
    const entry: { token: object; done: Promise<void>; saving?: Promise<unknown> } = {
      token,
      done: Promise.resolve()
    };
    this.backfills.set(account.id, entry);
    entry.done = this.backfillThreadMetadata(account, token, entry)
      .catch((error) => {
        console.warn("imap:backfill-stopped", {
          accountId: account.id,
          error: error instanceof Error ? error.message : String(error)
        });
      })
      .then(async () => {
        if (this.backfills.get(account.id)?.token !== token || !account.threadBackfill) return;
        // Tell clients the backfill ended so they reload the list once more.
        account.threadBackfill = undefined;
        await this.accounts.updateAccount(account).catch(() => undefined);
      })
      .finally(() => {
        if (this.backfills.get(account.id)?.token === token) {
          this.backfills.delete(account.id);
        }
      });
  }

  private async backfillThreadMetadata(
    account: MailAccount,
    token: object,
    entry: { saving?: Promise<unknown> }
  ): Promise<void> {
    const active = () => this.backfills.get(account.id)?.token === token;
    const pending = (await this.accounts.listInbox(account.userId))
      .filter((message) =>
        message.accountId === account.id &&
        message.messageId === undefined &&
        message.gmailThreadId === undefined &&
        message.references === undefined &&
        /^\d+$/.test(message.providerMessageId));

    const byMailbox = new Map<string, typeof pending>();
    for (const message of pending) {
      const group = byMailbox.get(message.mailbox);
      if (group) group.push(message);
      else byMailbox.set(message.mailbox, [message]);
    }
    if (pending.length === 0 || !active()) return;
    account.threadBackfill = "running";
    await this.accounts.updateAccount(account);
    for (const [mailbox, stored] of byMailbox) {
      // The synced mailbox is checked against the UIDVALIDITY the sync recorded.
      let expectedUidValidity = mailbox === this.options.mailbox ? account.uidValidity : undefined;
      const tracked = expectedUidValidity !== undefined;
      for (let i = 0; i < stored.length; i += MailSyncWorker.backfillBatch) {
        // Yield first so sync and other accounts are not starved.
        await new Promise((resolve) => setTimeout(resolve, this.options.backfillYieldMs ?? 250));
        if (!active()) return;
        const batch = stored.slice(i, i + MailSyncWorker.backfillBatch);
        const { uidValidity, messages } = await this.imap.fetchSummariesByUid(
          account, mailbox, batch.map((m) => Number(m.providerMessageId))
        );
        expectedUidValidity ??= uidValidity;
        // Same UIDs under a new UIDVALIDITY are other messages; never copy their headers.
        if (uidValidity !== expectedUidValidity) {
          throw new Error("Mailbox UIDVALIDITY changed during thread backfill");
        }
        const fetched = new Map(messages.map((m) => [m.providerMessageId, m]));
        if (!active()) return;
        // A sync that saw a new UIDVALIDITY meanwhile dropped this mail; saving would restore it.
        if (tracked && account.uidValidity !== expectedUidValidity) return;
        // Concurrent saves share one coalesced file write instead of one per message.
        entry.saving = Promise.all(batch.map((message) => {
          const found = fetched.get(message.providerMessageId);
          return this.accounts.saveIncomingMessage({
            ...message,
            messageId: found?.messageId,
            inReplyTo: found?.inReplyTo,
            references: found?.references ?? [],
            gmailThreadId: found?.gmailThreadId,
            // The snapshot predates this batch; the server's flags are newer.
            seen: found?.seen ?? message.seen,
            flagged: found?.flagged ?? message.flagged
          });
        }));
        await entry.saving;
      }
    }
  }

  // Saved UIDs point at other messages once the mailbox's UIDVALIDITY
  // changes, so the account's mail is dropped to be imported again.
  // Returns true when it dropped the mail.
  private async reconcileUidValidity(
    account: MailAccount,
    current: string
  ): Promise<boolean> {
    if (account.uidValidity === current) return false;
    const changed = account.uidValidity !== undefined;
    if (changed) {
      console.warn("imap:uidvalidity-changed", { accountId: account.id });
      await this.accounts.deleteMessages(account.id);
      account.lastSyncedAt = undefined;
    }
    account.uidValidity = current;
    await this.accounts.updateAccount(account);
    return changed;
  }

  // Resyncs continue after the last completed sync, however many messages
  // arrived while the server was disconnected.
  private async syncCursor(account: MailAccount): Promise<ImapSyncCursor | undefined> {
    if (account.syncedUid !== undefined) {
      return { uid: account.syncedUid, uidValidity: account.syncedUidValidity };
    }
    // Accounts synced before cursors were stored start after their newest mail.
    const uid = await this.newestStoredUid(account);
    return uid === undefined ? undefined : { uid };
  }

  private async newestStoredUid(account: MailAccount): Promise<number | undefined> {
    const uids = (await this.accounts.listInbox(account.userId))
      .filter((message) =>
        message.accountId === account.id && message.mailbox === this.options.mailbox
      )
      .map((message) => Number(message.providerMessageId))
      .filter(Number.isSafeInteger);
    // reduce, not Math.max(...uids): full imports can exceed the arg limit.
    return uids.length > 0
      ? uids.reduce((newest, uid) => Math.max(newest, uid))
      : undefined;
  }

  private initialSyncLimit(account: MailAccount): number | "all" | 0 {
    if (account.lastSyncedAt) return 25;
    if (account.initialSync?.includePreviousMessages === false) return 0;
    return account.initialSync?.limit ?? 100;
  }
}
