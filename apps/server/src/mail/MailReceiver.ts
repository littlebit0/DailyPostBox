import type {
  IncomingMessageContent,
  IncomingMessageSummary,
  MailAccount
} from "../domain/types.js";

export interface MailReceiver {
  testConnection(account: MailAccount): Promise<void>;
  fetchLatest(
    account: MailAccount,
    mailbox: string,
    limit?: number | "all"
  ): Promise<IncomingMessageSummary[]>;
  fetchMessageContent(
    account: MailAccount,
    mailbox: string,
    providerMessageId: string
  ): Promise<IncomingMessageContent>;
  watch?(
    account: MailAccount,
    mailbox: string,
    onMessage: (message: IncomingMessageSummary) => Promise<void>,
    onDisconnect?: (error: Error) => void
  ): Promise<() => Promise<void>>;
}
