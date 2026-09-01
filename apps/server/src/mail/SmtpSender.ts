import nodemailer from "nodemailer";
import type { TransportOptions } from "nodemailer";
import type { OAuthTokenManager } from "../auth/OAuthTokenManager.js";
import type { MailAccount, OutgoingMessageDraft } from "../domain/types.js";
import { resolveOutgoingSettings } from "../providers/resolveConnectionSettings.js";
import type { SecretResolver } from "../security/SecretResolver.js";
import type { MailSender, SendResult } from "./MailSender.js";

export class SmtpSender implements MailSender {
  constructor(
    private readonly secrets: SecretResolver,
    private readonly oauthTokens: OAuthTokenManager
  ) {}

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
    const accessToken = account.authMode === "oauth2"
      ? await this.oauthTokens.accessTokenFor(account, account.encryptedSecretRef)
      : null;

    const options: TransportOptions = {
      host: outgoing.host,
      port: outgoing.port,
      secure: outgoing.secure,
      requireTLS: !outgoing.secure,
      auth: (accessToken
        ? {
            type: "OAuth2",
            user: account.emailAddress,
            accessToken
          }
        : {
            user: account.emailAddress,
            pass: secret
          }) as TransportOptions["auth"]
    };

    return nodemailer.createTransport(options);
  }
}
