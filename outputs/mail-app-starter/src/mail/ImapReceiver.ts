import { ImapFlow } from "imapflow";
import type { IncomingMessageSummary, MailAccount } from "../domain/types.js";
import { getProvider } from "../providers/providerRegistry.js";
import { resolveIncomingSettings } from "../providers/resolveConnectionSettings.js";
import type { SecretResolver } from "../security/SecretResolver.js";
import type { MailReceiver } from "./MailReceiver.js";

export class ImapReceiver implements MailReceiver {
  constructor(private readonly secrets: SecretResolver) {}

  async testConnection(account: MailAccount): Promise<void> {
    const client = await this.createClient(account);
    try {
      await client.connect();
    } finally {
      await client.logout().catch(() => undefined);
    }
  }

  async fetchLatest(
    account: MailAccount,
    mailbox = "INBOX",
    limit: number | "all" = 25
  ): Promise<IncomingMessageSummary[]> {
    const client = await this.createClient(account);
    await client.connect();

    try {
      const lock = await client.getMailboxLock(mailbox);
      try {
        const messages: IncomingMessageSummary[] = [];
        for await (const message of client.fetch("1:*", {
          envelope: true,
          flags: true,
          uid: true
        })) {
          const envelope = message.envelope;
          if (!envelope) continue;

          messages.push({
            accountId: account.id,
            providerMessageId: String(message.uid),
            mailbox,
            from: envelope.from?.map((item) => item.address).filter(Boolean).join(", ") ?? "",
            subject: envelope.subject ?? "",
            receivedAt: envelope.date ?? new Date(),
            hasAttachments: false
          });
        }

        return limit === "all" ? messages : messages.slice(-limit);
      } finally {
        lock.release();
      }
    } finally {
      await client.logout().catch(() => undefined);
    }
  }

  async watch(
    account: MailAccount,
    mailbox: string,
    onMessage: (message: IncomingMessageSummary) => Promise<void>
  ): Promise<() => Promise<void>> {
    const provider = getProvider(account.providerId);
    if (!provider.incoming.supportsIdle) {
      throw new Error(`${provider.displayName} does not support IMAP IDLE`);
    }

    const client = await this.createClient(account);
    await client.connect();
    await client.mailboxOpen(mailbox);

    client.on("exists", async () => {
      const latest = await this.fetchLatest(account, mailbox);
      const lastMessage = latest.at(-1);
      if (lastMessage) await onMessage(lastMessage);
    });

    await client.idle();

    return async () => {
      await client.logout().catch(() => undefined);
    };
  }

  private async createClient(account: MailAccount): Promise<ImapFlow> {
    const incoming = resolveIncomingSettings(account);
    const secret = await this.secrets.resolve(account.encryptedSecretRef);
    const oauth = parseOAuthSecret(secret);

    return new ImapFlow({
      host: incoming.host,
      port: incoming.port,
      secure: incoming.secure,
      auth: oauth && account.authMode === "oauth2"
        ? {
            user: account.emailAddress,
            accessToken: oauth.accessToken
          }
        : {
            user: account.emailAddress,
            pass: secret
          },
      logger: false
    });
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
