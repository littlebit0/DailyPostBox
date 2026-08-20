import type { IncomingMessageSummary, MailAccount } from "../domain/types.js";

export interface MailReceiver {
  testConnection(account: MailAccount): Promise<void>;
  fetchLatest(
    account: MailAccount,
    mailbox: string,
    limit?: number | "all"
  ): Promise<IncomingMessageSummary[]>;
  watch?(
    account: MailAccount,
    mailbox: string,
    onMessage: (message: IncomingMessageSummary) => Promise<void>
  ): Promise<() => Promise<void>>;
}
