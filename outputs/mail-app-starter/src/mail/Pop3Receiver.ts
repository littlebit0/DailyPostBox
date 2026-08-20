import type { IncomingMessageSummary, MailAccount } from "../domain/types.js";
import type { MailReceiver } from "./MailReceiver.js";

export class Pop3Receiver implements MailReceiver {
  async testConnection(_account: MailAccount): Promise<void> {
    // Plug in a POP3 client such as poplib or mailpop3 here.
  }

  async fetchLatest(
    account: MailAccount,
    mailbox = "INBOX",
    _limit: number | "all" = 25
  ): Promise<IncomingMessageSummary[]> {
    // POP3 usually has no folder model and no push/idle support.
    // Persist UIDL values per account to detect newly received messages.
    return [
      {
        accountId: account.id,
        providerMessageId: "placeholder-pop3-uidl",
        mailbox,
        from: "",
        subject: "",
        receivedAt: new Date(),
        hasAttachments: false
      }
    ].filter((message) => message.subject);
  }
}
