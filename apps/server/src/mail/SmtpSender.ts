import nodemailer from "nodemailer";
import type { TransportOptions } from "nodemailer";
import type { MailAccount, OutgoingMessageDraft } from "../domain/types.js";
import { resolveOutgoingSettings } from "../providers/resolveConnectionSettings.js";
import type { SecretResolver } from "../security/SecretResolver.js";
import type { MailSender, SendResult } from "./MailSender.js";

export class SmtpSender implements MailSender {
  constructor(private readonly secrets: SecretResolver) {}

  async testConnection(account: MailAccount): Promise<void> {
    const transporter = await this.createTransporter(account);
    await transporter.verify();
  }

  async send(account: MailAccount, draft: OutgoingMessageDraft): Promise<SendResult> {
    const transporter = await this.createTransporter(account);
    const result = await transporter.sendMail({
      from: account.emailAddress,
      to: draft.to,
      cc: draft.cc,
      bcc: draft.bcc,
      subject: draft.subject,
      text: draft.text,
      html: draft.html
    });

    return {
      providerMessageId: result.messageId,
      accepted: result.accepted.map(String),
      rejected: result.rejected.map(String)
    };
  }

  private async createTransporter(account: MailAccount) {
    const outgoing = resolveOutgoingSettings(account);
    const secret = await this.secrets.resolve(account.encryptedSecretRef);
    const oauth = parseOAuthSecret(secret);

    const options: TransportOptions = {
      host: outgoing.host,
      port: outgoing.port,
      secure: outgoing.secure,
      auth: (oauth && account.authMode === "oauth2"
        ? {
            type: "OAuth2",
            user: account.emailAddress,
            accessToken: oauth.accessToken
          }
        : {
            user: account.emailAddress,
            pass: secret
          }) as TransportOptions["auth"]
    };

    return nodemailer.createTransport(options);
  }
}

function parseOAuthSecret(secret: string): { accessToken: string } | null {
  try {
    const payload = JSON.parse(secret) as { type?: string; accessToken?: string };
    if (payload.type === "oauth2" && payload.accessToken) {
      return { accessToken: payload.accessToken };
    }
  } catch {
    return null;
  }
  return null;
}
