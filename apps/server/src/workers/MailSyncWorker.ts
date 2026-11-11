import type { MailAccount, IncomingMessageSummary } from "../domain/types.js";
import type { ImapReceiver } from "../mail/ImapReceiver.js";
import type { Pop3Receiver } from "../mail/Pop3Receiver.js";
import type { PushNotifier } from "../notifications/PushNotifier.js";
import type { AccountRepository } from "./AccountRepository.js";

export interface MailSyncWorkerOptions {
  pop3PollIntervalMs: number;
  mailbox: string;
  imapReconnectBaseDelayMs: number;
  imapReconnectMaxDelayMs: number;
}

export class MailSyncWorker {
  private readonly stopHandlers = new Map<string, () => Promise<void>>();
  private readonly pollingTimers = new Map<string, NodeJS.Timeout>();
  private readonly syncPromises = new Map<string, Promise<void>>();

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
    if (account.incomingProtocol === "imap") {
      if (!this.stopHandlers.has(account.id)) {
        await this.startImapAccount(account);
      }
      await this.syncAccount(account).catch(() => undefined);
      return;
    }

    await this.syncAccount(account).catch(() => undefined);
    if (this.pollingTimers.has(account.id)) {
      return;
    }

    this.startPop3Account(account);
  }

  async syncAccount(account: MailAccount): Promise<void> {
    const activeSync = this.syncPromises.get(account.id);
    if (activeSync) return activeSync;

    const sync = this.performSync(account).finally(() => {
      if (this.syncPromises.get(account.id) === sync) {
        this.syncPromises.delete(account.id);
      }
    });
    this.syncPromises.set(account.id, sync);
    return sync;
  }

  private async performSync(account: MailAccount): Promise<void> {
    const limit = this.initialSyncLimit(account);
    account.syncStatus = "syncing";
    account.syncError = undefined;
    await this.accounts.updateAccount(account);

    try {
      if (limit !== 0) {
        if (account.incomingProtocol === "imap") {
          await this.imap.fetchLatestBatches(
            account,
            this.options.mailbox,
            limit,
            async (messages) => {
              await Promise.all(
                messages.map((message) =>
                  this.handleIncoming(account, message, false)
                )
              );
            }
          );
        } else {
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
      }

      account.syncStatus = "idle";
      account.lastSyncedAt = new Date();
      await this.accounts.updateAccount(account);
    } catch (error) {
      account.syncStatus = "error";
      account.syncError = error instanceof Error ? error.message : String(error);
      await this.accounts.updateAccount(account);
      throw error;
    }
  }

  async stop(): Promise<void> {
    for (const timer of this.pollingTimers.values()) clearInterval(timer);
    this.pollingTimers.clear();

    await Promise.all(
      [...this.stopHandlers.values()].map((stop) => stop().catch(() => undefined))
    );
    this.stopHandlers.clear();
  }

  async stopAccount(accountId: string): Promise<void> {
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

    const connect = async (): Promise<void> => {
      if (stopped) return;

      try {
        activeStop = await this.imap.watch?.(
          account,
          this.options.mailbox,
          async (message) => this.handleIncoming(account, message),
          scheduleReconnect
        );
        reconnectDelay = this.options.imapReconnectBaseDelayMs;
      } catch (error) {
        scheduleReconnect(error instanceof Error ? error : new Error(String(error)));
      }
    };

    this.stopHandlers.set(account.id, async () => {
      stopped = true;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      reconnectTimer = undefined;
      await activeStop?.().catch(() => undefined);
      activeStop = undefined;
    });

    await connect();
  }

  private startPop3Account(account: MailAccount): void {
    const poll = async () => {
      const messages = await this.pop3.fetchLatest(account, this.options.mailbox, 25);
      await Promise.all(messages.map((message) => this.handleIncoming(account, message)));
    };

    void poll();
    const timer = setInterval(() => void poll(), this.options.pop3PollIntervalMs);
    this.pollingTimers.set(account.id, timer);
  }

  private async handleIncoming(
    account: MailAccount,
    message: IncomingMessageSummary,
    notify = true
  ): Promise<void> {
    const isNew = await this.accounts.saveIncomingMessage(message);
    if (!notify || !isNew) return;
    const targets = await this.accounts.listPushTargets(account.userId);
    await this.push.notifyNewMessage(targets, message);
  }

  private initialSyncLimit(account: MailAccount): number | "all" | 0 {
    if (account.lastSyncedAt) return 25;
    if (account.initialSync?.includePreviousMessages === false) return 0;
    return account.initialSync?.limit ?? 100;
  }
}
