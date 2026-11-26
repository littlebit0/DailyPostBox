import type {
  AttachmentDownload,
  IncomingMessageContent,
  IncomingMessageSummary,
  MailAccount
} from "../domain/types.js";
import type { MailReceiver } from "./MailReceiver.js";

export const pop3UnsupportedMessage =
  "POP3 수신은 아직 지원하지 않습니다. IMAP으로 연결하세요.";

// statusCode makes the API answer 400 with this message instead of a
// generic connection failure.
export function pop3Unsupported(): Error {
  return Object.assign(new Error(pop3UnsupportedMessage), { statusCode: 400 });
}

// shortcut: POP3 is not implemented, so every call fails instead of
// reporting an empty mailbox as a successful sync; implement with a POP3
// client (UIDL tracking) before accepting POP3 accounts again.
export class Pop3Receiver implements MailReceiver {
  async testConnection(_account: MailAccount): Promise<void> {
    throw pop3Unsupported();
  }

  async fetchLatest(
    _account: MailAccount,
    _mailbox = "INBOX",
    _limit: number | "all" = 25
  ): Promise<IncomingMessageSummary[]> {
    throw pop3Unsupported();
  }

  async fetchMessageContent(
    _account: MailAccount,
    _mailbox: string,
    _providerMessageId: string
  ): Promise<IncomingMessageContent> {
    throw pop3Unsupported();
  }

  async downloadAttachment(
    _account: MailAccount,
    _mailbox: string,
    _providerMessageId: string,
    _part: string
  ): Promise<AttachmentDownload | null> {
    throw pop3Unsupported();
  }
}
