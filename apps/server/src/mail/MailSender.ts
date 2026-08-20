import type { MailAccount, OutgoingMessageDraft } from "../domain/types.js";

export interface SendResult {
  providerMessageId?: string;
  accepted: string[];
  rejected: string[];
}

export interface MailSender {
  testConnection(account: MailAccount): Promise<void>;
  send(account: MailAccount, draft: OutgoingMessageDraft): Promise<SendResult>;
}
