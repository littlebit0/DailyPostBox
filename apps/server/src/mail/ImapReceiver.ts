import { ImapFlow } from "imapflow";
import type { FetchMessageObject, MessageStructureObject } from "imapflow";
import { simpleParser } from "mailparser";
import type { OAuthTokenManager } from "../auth/OAuthTokenManager.js";
import type {
  IncomingMessageContent,
  IncomingMessageLink,
  IncomingMessageSummary,
  MailAccount
} from "../domain/types.js";
import { getProvider } from "../providers/providerRegistry.js";
import { resolveIncomingSettings } from "../providers/resolveConnectionSettings.js";
import type { SecretResolver } from "../security/SecretResolver.js";
import type { MailReceiver } from "./MailReceiver.js";
import { newestFirstUidBatches } from "./imapSequenceRanges.js";
import { extractMessageLinks } from "./messageLinks.js";

export class ImapReceiver implements MailReceiver {
  private static readonly maxBodyBytes = 2 * 1024 * 1024;

  constructor(
    private readonly secrets: SecretResolver,
    private readonly oauthTokens: OAuthTokenManager
  ) {}

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
    const messages: IncomingMessageSummary[] = [];
    await this.fetchLatestBatches(account, mailbox, limit, async (batch) => {
      messages.push(...batch);
    });
    return messages;
  }

  async fetchLatestBatches(
    account: MailAccount,
    mailbox: string,
    limit: number | "all",
    onBatch: (messages: IncomingMessageSummary[]) => Promise<void>
  ): Promise<void> {
    const initial = await this.withConnectionRetry(async () => {
      return this.withConnectedClient(account, async (client) => {
        const openedMailbox = await client.mailboxOpen(mailbox, {
          readOnly: true
        });
        const uids = await client.search({ all: true }, { uid: true });
        const batches = newestFirstUidBatches(uids || [], limit);
        const firstUids = batches.at(0);

        return {
          uidValidity: openedMailbox.uidValidity,
          firstBatch: firstUids
            ? await this.fetchUids(client, account, mailbox, firstUids)
            : [],
          remainingBatches: batches.slice(1)
        };
      });
    });

    if (initial.firstBatch.length > 0) {
      await onBatch(initial.firstBatch);
    }

    // Some providers close long-running IMAP sessions during large initial
    // imports. Isolating each batch keeps already-saved batches visible and
    // lets a disconnected batch retry with a fresh connection.
    for (const uids of initial.remainingBatches) {
      const batch = await this.withConnectionRetry(async () => {
        return this.withConnectedClient(account, async (client) => {
          const openedMailbox = await client.mailboxOpen(mailbox, {
            readOnly: true
          });
          if (openedMailbox.uidValidity !== initial.uidValidity) {
            throw new Error("Mailbox UIDVALIDITY changed during import");
          }
          return this.fetchUids(client, account, mailbox, uids);
        });
      });

      if (batch.length > 0) {
        await onBatch(batch);
      }
    }
  }

  async fetchMessageContent(
    account: MailAccount,
    mailbox: string,
    providerMessageId: string
  ): Promise<IncomingMessageContent> {
    const client = await this.createClient(account);
    await client.connect();

    try {
      await client.mailboxOpen(mailbox, { readOnly: true });
      const message = await client.fetchOne(
        providerMessageId,
        { bodyStructure: true },
        { uid: true }
      );
      if (!message || !message.bodyStructure) {
        throw new Error("Message body was not found on the IMAP server.");
      }

      const bodyParts = selectBodyParts(message.bodyStructure);
      let htmlFallback: IncomingMessageContent | null = null;
      let htmlLinks: IncomingMessageLink[] = [];

      for (const bodyPart of bodyParts) {
        const download = await client.download(
          providerMessageId,
          bodyPart.part ?? "1",
          {
            uid: true,
            maxBytes: ImapReceiver.maxBodyBytes
          }
        );
        const content = await readBodyStream(download.content);
        const truncated = content.length >= ImapReceiver.maxBodyBytes;
        const decoded = content.toString("utf8");

        if (bodyPart.type.toLowerCase() !== "text/html") {
          const text = cleanMessageText(decoded);
          if (text) return { text, truncated, links: htmlLinks };
          continue;
        }

        htmlLinks = mergeMessageLinks(
          htmlLinks,
          extractMessageLinks(decoded)
        );

        const parsed = await simpleParser(
          Buffer.concat([
            Buffer.from(
              "MIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\n\r\n"
            ),
            content
          ]),
          {
            keepCidLinks: true,
            maxHtmlLengthToParse: ImapReceiver.maxBodyBytes
          }
        );
        const text = cleanMessageText(parsed.text ?? "");
        if (text && !htmlFallback) {
          htmlFallback = {
            text,
            truncated,
            links: htmlLinks
          };
        }
      }

      if (htmlFallback) return { ...htmlFallback, links: htmlLinks };
      return { text: "", truncated: false, links: [] };
    } finally {
      await client.logout().catch(() => undefined);
    }
  }

  async watch(
    account: MailAccount,
    mailbox: string,
    onMessage: (message: IncomingMessageSummary) => Promise<void>,
    onDisconnect?: (error: Error) => void
  ): Promise<() => Promise<void>> {
    const provider = getProvider(account.providerId);
    if (!provider.incoming.supportsIdle) {
      throw new Error(`${provider.displayName} does not support IMAP IDLE`);
    }

    const client = await this.createClient(account);
    let stopped = false;
    let disconnectReported = false;
    let handlingExists = false;

    const reportDisconnect = (error: Error) => {
      if (stopped || disconnectReported) return;
      disconnectReported = true;
      onDisconnect?.(error);
    };

    client.on("error", reportDisconnect);
    client.on("close", () => {
      reportDisconnect(new Error("IMAP connection closed."));
    });

    try {
      await client.connect();
      await client.mailboxOpen(mailbox);
    } catch (error) {
      stopped = true;
      await client.logout().catch(() => undefined);
      throw error;
    }

    client.on("exists", () => {
      if (handlingExists || stopped) return;
      handlingExists = true;

      void this.fetchLatest(account, mailbox, 1)
        .then((latest) => latest.at(-1))
        .then((message) => message ? onMessage(message) : undefined)
        .catch((error: unknown) => {
          reportDisconnect(toError(error));
        })
        .finally(() => {
          handlingExists = false;
        });
    });

    return async () => {
      stopped = true;
      await client.logout().catch(() => undefined);
    };
  }

  private async createClient(account: MailAccount): Promise<ImapFlow> {
    const incoming = resolveIncomingSettings(account);
    const secret = await this.secrets.resolve(account.encryptedSecretRef);
    const accessToken = account.authMode === "oauth2"
      ? await this.oauthTokens.accessTokenFor(account, account.encryptedSecretRef)
      : null;

    const client = new ImapFlow({
      host: incoming.host,
      port: incoming.port,
      secure: incoming.secure,
      auth: accessToken
        ? {
            user: account.emailAddress,
            accessToken
          }
        : {
            user: account.emailAddress,
            pass: secret
          },
      logger: false
    });

    // ImapFlow emits EventEmitter errors in addition to rejecting commands.
    // Keeping a listener attached prevents a transient socket timeout from
    // terminating the entire mail server process.
    client.on("error", () => undefined);
    return client;
  }

  private async withConnectedClient<T>(
    account: MailAccount,
    operation: (client: ImapFlow) => Promise<T>
  ): Promise<T> {
    const client = await this.createClient(account);
    try {
      await client.connect();
      return await operation(client);
    } finally {
      await client.logout().catch(() => undefined);
    }
  }

  private async fetchUids(
    client: ImapFlow,
    account: MailAccount,
    mailbox: string,
    uids: number[]
  ): Promise<IncomingMessageSummary[]> {
    const batch: IncomingMessageSummary[] = [];
    for await (const message of client.fetch(uids, {
      envelope: true,
      flags: true,
      uid: true
    }, { uid: true })) {
      const summary = toIncomingMessage(account, mailbox, message);
      if (summary) batch.push(summary);
    }
    return batch;
  }

  private async withConnectionRetry<T>(
    operation: () => Promise<T>
  ): Promise<T> {
    const retryDelaysMs = [500, 1_500];

    for (let attempt = 0; ; attempt += 1) {
      try {
        return await operation();
      } catch (error) {
        if (isAuthenticationFailure(error) || attempt >= retryDelaysMs.length) {
          throw error;
        }
        await delay(retryDelaysMs[attempt]);
      }
    }
  }
}

function toIncomingMessage(
  account: MailAccount,
  mailbox: string,
  message: FetchMessageObject
): IncomingMessageSummary | null {
  const envelope = message.envelope;
  if (!envelope) return null;

  return {
    accountId: account.id,
    providerMessageId: String(message.uid),
    mailbox,
    from: envelope.from?.map((item) => item.address).filter(Boolean).join(", ") ?? "",
    subject: envelope.subject ?? "",
    receivedAt: envelope.date instanceof Date ? envelope.date : new Date(),
    hasAttachments: false
  };
}

function toError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

function isAuthenticationFailure(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;

  const candidate = error as {
    authenticationFailed?: boolean;
    code?: unknown;
  };
  return candidate.authenticationFailed === true ||
    candidate.code === "AUTHENTICATIONFAILED";
}

async function delay(milliseconds: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function selectBodyParts(
  bodyStructure: MessageStructureObject
): MessageStructureObject[] {
  const candidates: MessageStructureObject[] = [];

  const visit = (part: MessageStructureObject): void => {
    if (part.disposition?.toLowerCase() === "attachment") return;
    for (const child of part.childNodes ?? []) visit(child);

    const type = part.type.toLowerCase();
    if (type === "text/plain" || type === "text/html") {
      candidates.push(part);
    }
  };

  visit(bodyStructure);
  // Read HTML alternatives first to collect anchor labels, then display the
  // cleaner plain-text alternative whenever the message provides one.
  return [
    ...candidates.filter((part) => part.type.toLowerCase() === "text/html"),
    ...candidates.filter((part) => part.type.toLowerCase() === "text/plain")
  ];
}

async function readBodyStream(
  stream: NodeJS.ReadableStream
): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of stream) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}

function cleanMessageText(value: string): string {
  return value
    .replace(/[\u200B-\u200D\uFEFF]/g, "")
    .replace(/\u00A0/g, " ")
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function mergeMessageLinks(
  current: IncomingMessageLink[],
  additions: IncomingMessageLink[]
): IncomingMessageLink[] {
  const seen = new Set(current.map((link) => `${link.url}\u0000${link.label}`));
  const merged = [...current];

  for (const link of additions) {
    const key = `${link.url}\u0000${link.label}`;
    if (seen.has(key)) continue;
    seen.add(key);
    merged.push(link);
  }
  return merged;
}
