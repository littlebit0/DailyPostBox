import type { MailAccount } from "../domain/types.js";
import type { PushTarget } from "../notifications/PushNotifier.js";
import type { IncomingMessageSummary, MessageFlagChange } from "../domain/types.js";

/// An address the user has sent mail to; the only trusted source for recipient suggestions.
export interface SentRecipient {
  accountId: string;
  address: string;
  count: number;
  lastSentAt: Date;
}

export function addSentRecipients(
  store: Map<string, SentRecipient>,
  accountId: string,
  addresses: string[],
  sentAt: Date
): void {
  for (const raw of new Set(addresses.map((item) => item.trim().toLowerCase()))) {
    if (!raw.includes("@")) continue;
    const key = `${accountId}:${raw}`;
    const current = store.get(key);
    store.set(key, {
      accountId,
      address: raw,
      count: (current?.count ?? 0) + 1,
      lastSentAt: current && current.lastSentAt > sentAt ? current.lastSentAt : sentAt
    });
  }
}

export interface AccountRepository {
  listActiveAccounts(): Promise<MailAccount[]>;
  getAccount(accountId: string): Promise<MailAccount | undefined>;
  addAccount(account: MailAccount): Promise<void>;
  updateAccount(account: MailAccount): Promise<void>;
  deleteAccount(accountId: string): Promise<void>;
  listPushTargets(userId: string): Promise<PushTarget[]>;
  savePushTarget(target: PushTarget): Promise<void>;
  deletePushTarget(target: PushTarget): Promise<void>;
  listInbox(userId: string): Promise<IncomingMessageSummary[]>;
  saveIncomingMessage(message: IncomingMessageSummary): Promise<boolean>;
  recordSentRecipients(accountId: string, addresses: string[], sentAt: Date): Promise<void>;
  listSentRecipients(userId: string): Promise<SentRecipient[]>;
  updateMessageFlags(
    accountId: string,
    providerMessageId: string,
    change: MessageFlagChange
  ): Promise<void>;
  deleteMessages(accountId: string): Promise<void>;
}

export class InMemoryAccountRepository implements AccountRepository {
  private readonly accounts: MailAccount[] = [];
  private readonly messages = new Map<string, IncomingMessageSummary>();
  private readonly pushTargets: PushTarget[] = [];
  private readonly sentRecipients = new Map<string, SentRecipient>();

  async listActiveAccounts(): Promise<MailAccount[]> {
    return this.accounts;
  }

  async getAccount(accountId: string): Promise<MailAccount | undefined> {
    return this.accounts.find((account) => account.id === accountId);
  }

  async addAccount(account: MailAccount): Promise<void> {
    const duplicate = this.accounts.some(
      (item) => item.userId === account.userId &&
        item.providerId === account.providerId &&
        item.emailAddress.toLowerCase() === account.emailAddress.toLowerCase()
    );
    if (duplicate) throw new Error("이미 연결된 이메일 계정입니다.");

    this.accounts.push(account);
  }

  async updateAccount(account: MailAccount): Promise<void> {
    const index = this.accounts.findIndex((item) => item.id === account.id);
    if (index >= 0) this.accounts[index] = account;
  }

  async deleteAccount(accountId: string): Promise<void> {
    const index = this.accounts.findIndex((account) => account.id === accountId);
    if (index >= 0) this.accounts.splice(index, 1);

    for (const key of this.messages.keys()) {
      if (key.startsWith(`${accountId}:`)) this.messages.delete(key);
    }
    for (const [key, item] of this.sentRecipients) {
      if (item.accountId === accountId) this.sentRecipients.delete(key);
    }
  }

  async listPushTargets(userId: string): Promise<PushTarget[]> {
    return this.pushTargets.filter((target) => target.userId === userId);
  }

  async savePushTarget(target: PushTarget): Promise<void> {
    const existingIndex = this.pushTargets.findIndex(
      (item) => item.userId === target.userId && item.deviceToken === target.deviceToken
    );

    if (existingIndex >= 0) {
      this.pushTargets[existingIndex] = target;
      return;
    }

    this.pushTargets.push(target);
  }

  async deletePushTarget(target: PushTarget): Promise<void> {
    const index = this.pushTargets.findIndex(
      (item) => item.userId === target.userId && item.deviceToken === target.deviceToken
    );
    if (index >= 0) this.pushTargets.splice(index, 1);
  }

  async listInbox(userId: string): Promise<IncomingMessageSummary[]> {
    const accountIds = new Set(
      this.accounts.filter((account) => account.userId === userId).map((account) => account.id)
    );

    return [...this.messages.values()]
      .filter((message) => accountIds.has(message.accountId))
      .sort((a, b) => b.receivedAt.getTime() - a.receivedAt.getTime());
  }

  async deleteMessages(accountId: string): Promise<void> {
    for (const [key, message] of this.messages) {
      if (message.accountId === accountId) this.messages.delete(key);
    }
  }

  async saveIncomingMessage(message: IncomingMessageSummary): Promise<boolean> {
    // A sync still running for a deleted account must not leave mail behind.
    if (!this.accounts.some((account) => account.id === message.accountId)) {
      return false;
    }
    const key = `${message.accountId}:${message.providerMessageId}`;
    const isNew = !this.messages.has(key);
    this.messages.set(key, message);
    return isNew;
  }

  async recordSentRecipients(accountId: string, addresses: string[], sentAt: Date): Promise<void> {
    addSentRecipients(this.sentRecipients, accountId, addresses, sentAt);
  }

  async listSentRecipients(userId: string): Promise<SentRecipient[]> {
    const accountIds = new Set(
      this.accounts.filter((account) => account.userId === userId).map((account) => account.id)
    );
    return [...this.sentRecipients.values()].filter((item) => accountIds.has(item.accountId));
  }

  async updateMessageFlags(
    accountId: string,
    providerMessageId: string,
    change: MessageFlagChange
  ): Promise<void> {
    const key = `${accountId}:${providerMessageId}`;
    const message = this.messages.get(key);
    if (message) this.messages.set(key, { ...message, ...change });
  }
}
