import type { MailAccount } from "../domain/types.js";
import type { PushTarget } from "../notifications/PushNotifier.js";
import type { IncomingMessageSummary } from "../domain/types.js";

export interface AccountRepository {
  listActiveAccounts(): Promise<MailAccount[]>;
  getAccount(accountId: string): Promise<MailAccount | undefined>;
  addAccount(account: MailAccount): Promise<void>;
  updateAccount(account: MailAccount): Promise<void>;
  deleteAccount(accountId: string): Promise<void>;
  listPushTargets(userId: string): Promise<PushTarget[]>;
  savePushTarget(target: PushTarget): Promise<void>;
  listInbox(userId: string): Promise<IncomingMessageSummary[]>;
  getMessage(userId: string, messageId: string): Promise<IncomingMessageSummary | undefined>;
  saveIncomingMessage(message: IncomingMessageSummary): Promise<boolean>;
}

export class InMemoryAccountRepository implements AccountRepository {
  private readonly accounts: MailAccount[] = [];
  private readonly messages = new Map<string, IncomingMessageSummary>();
  private readonly pushTargets: PushTarget[] = [];

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

  async listInbox(userId: string): Promise<IncomingMessageSummary[]> {
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
    const key = `${message.accountId}:${message.providerMessageId}`;
    const isNew = !this.messages.has(key);
    this.messages.set(key, message);
    return isNew;
  }
}
