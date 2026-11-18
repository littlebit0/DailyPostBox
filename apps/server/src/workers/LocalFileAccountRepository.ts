import { dirname } from "node:path";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import type { IncomingMessageSummary, MailAccount } from "../domain/types.js";
import type { PushTarget } from "../notifications/PushNotifier.js";
import type { AccountRepository } from "./AccountRepository.js";

type StoredAccount = Omit<MailAccount, "createdAt" | "updatedAt" | "lastSyncedAt"> & {
  createdAt: string;
  updatedAt: string;
  lastSyncedAt?: string;
};

type StoredMessage = Omit<IncomingMessageSummary, "receivedAt"> & {
  receivedAt: string;
};

interface StoredState {
  accounts: StoredAccount[];
  messages: StoredMessage[];
  pushTargets: PushTarget[];
}

export class LocalFileAccountRepository implements AccountRepository {
  private accounts: MailAccount[] = [];
  private readonly messages = new Map<string, IncomingMessageSummary>();
  private pushTargets: PushTarget[] = [];
  private loadPromise?: Promise<void>;
  private persistPromise?: Promise<void>;
  private dirty = false;

  constructor(private readonly filePath: string) {}

  async listActiveAccounts(): Promise<MailAccount[]> {
    await this.ensureLoaded();
    return this.accounts;
  }

  async getAccount(accountId: string): Promise<MailAccount | undefined> {
    await this.ensureLoaded();
    return this.accounts.find((account) => account.id === accountId);
  }

  async addAccount(account: MailAccount): Promise<void> {
    await this.ensureLoaded();
    if (this.hasDuplicate(account)) {
      throw new Error("이미 연결된 이메일 계정입니다.");
    }

    this.accounts.push(account);
    await this.persist();
  }

  async updateAccount(account: MailAccount): Promise<void> {
    await this.ensureLoaded();
    const index = this.accounts.findIndex((item) => item.id === account.id);
    if (index >= 0) {
      this.accounts[index] = account;
      await this.persist();
    }
  }

  async deleteAccount(accountId: string): Promise<void> {
    await this.ensureLoaded();
    const index = this.accounts.findIndex((account) => account.id === accountId);
    if (index >= 0) this.accounts.splice(index, 1);

    for (const [key, message] of this.messages) {
      if (message.accountId === accountId) this.messages.delete(key);
    }
    await this.persist();
  }

  async listPushTargets(userId: string): Promise<PushTarget[]> {
    await this.ensureLoaded();
    return this.pushTargets.filter((target) => target.userId === userId);
  }

  async savePushTarget(target: PushTarget): Promise<void> {
    await this.ensureLoaded();
    const index = this.pushTargets.findIndex(
      (item) => item.userId === target.userId && item.deviceToken === target.deviceToken
    );
    if (index >= 0) {
      this.pushTargets[index] = target;
    } else {
      this.pushTargets.push(target);
    }
    await this.persist();
  }

  async deletePushTarget(target: PushTarget): Promise<void> {
    await this.ensureLoaded();
    const index = this.pushTargets.findIndex(
      (item) => item.userId === target.userId && item.deviceToken === target.deviceToken
    );
    if (index < 0) return;
    this.pushTargets.splice(index, 1);
    await this.persist();
  }

  async listInbox(userId: string): Promise<IncomingMessageSummary[]> {
    await this.ensureLoaded();
    const accountIds = new Set(
      this.accounts.filter((account) => account.userId === userId).map((account) => account.id)
    );
    return [...this.messages.values()]
      .filter((message) => accountIds.has(message.accountId))
      .sort((a, b) => b.receivedAt.getTime() - a.receivedAt.getTime());
  }

  async getMessage(
    userId: string,
    messageId: string
  ): Promise<IncomingMessageSummary | undefined> {
    const inbox = await this.listInbox(userId);
    return inbox.find((message) => message.providerMessageId === messageId);
  }

  async saveIncomingMessage(message: IncomingMessageSummary): Promise<boolean> {
    await this.ensureLoaded();
    const key = messageKey(message);
    const isNew = !this.messages.has(key);
    this.messages.set(key, message);
    await this.persist();
    return isNew;
  }

  private async ensureLoaded(): Promise<void> {
    this.loadPromise ??= this.load();
    await this.loadPromise;
  }

  private async load(): Promise<void> {
    try {
      const raw = await readFile(this.filePath, "utf8");
      const state = JSON.parse(raw) as StoredState;
      this.accounts = (state.accounts ?? []).map((account) => ({
        ...account,
        createdAt: new Date(account.createdAt),
        updatedAt: new Date(account.updatedAt),
        lastSyncedAt: account.lastSyncedAt ? new Date(account.lastSyncedAt) : undefined
      }));
      this.pushTargets = state.pushTargets ?? [];
      for (const message of state.messages ?? []) {
        if (message.providerMessageId === `welcome-${message.accountId}`) {
          continue;
        }
        const hydrated = { ...message, receivedAt: new Date(message.receivedAt) };
        this.messages.set(messageKey(hydrated), hydrated);
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }

  private hasDuplicate(candidate: MailAccount): boolean {
    return this.accounts.some(
      (account) => account.userId === candidate.userId &&
        account.providerId === candidate.providerId &&
        account.emailAddress.toLowerCase() === candidate.emailAddress.toLowerCase()
    );
  }

  private persist(): Promise<void> {
    this.dirty = true;
    this.persistPromise ??= this.flush().finally(() => {
      this.persistPromise = undefined;
    });
    return this.persistPromise;
  }

  private async flush(): Promise<void> {
    await new Promise((resolve) => setTimeout(resolve, 10));
    while (this.dirty) {
      this.dirty = false;
      const state: StoredState = {
        accounts: this.accounts.map((account) => ({
          ...account,
          createdAt: account.createdAt.toISOString(),
          updatedAt: account.updatedAt.toISOString(),
          lastSyncedAt: account.lastSyncedAt?.toISOString()
        })),
        messages: [...this.messages.values()].map((message) => ({
          ...message,
          receivedAt: message.receivedAt.toISOString()
        })),
        pushTargets: this.pushTargets
      };

      await mkdir(dirname(this.filePath), { recursive: true, mode: 0o700 });
      const temporaryPath = `${this.filePath}.tmp`;
      await writeFile(temporaryPath, JSON.stringify(state), { mode: 0o600 });
      await rename(temporaryPath, this.filePath);
    }
  }
}

function messageKey(message: IncomingMessageSummary): string {
  return `${message.accountId}:${message.providerMessageId}`;
}
