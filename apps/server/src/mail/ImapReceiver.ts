import { ImapFlow } from "imapflow";
import type {
  FetchMessageObject,
  MessageStructureObject,
  SearchObject
} from "imapflow";
import { simpleParser } from "mailparser";
import { parseAuthenticationFailures } from "./authenticationResults.js";
import type { OAuthTokenManager } from "../auth/OAuthTokenManager.js";
import type {
  AttachmentDownload,
  CalendarInvite,
  IncomingMessageAttachment,
  IncomingMessageContent,
  IncomingMessageLink,
  IncomingMessageSummary,
  ListUnsubscribe,
  MailAccount,
  MessageFlagChange,
  MessageThreadHeaders
} from "../domain/types.js";
import { getProvider } from "../providers/providerRegistry.js";
import {
  resolveIncomingSettings,
  supportsImapIdle
} from "../providers/resolveConnectionSettings.js";
import type { SecretResolver } from "../security/SecretResolver.js";
import type { MailReceiver } from "./MailReceiver.js";
import {
  batchLimit,
  cursorUid,
  latestUidSearchQuery,
  newestFirstUidBatches
} from "./imapSequenceRanges.js";
import { isAuthenticationFailure } from "./authenticationFailure.js";
import {
  classificationHeaderNames,
  classifyMessage,
  parseRawHeaders
} from "./classifyMessage.js";
import { Readable } from "node:stream";
import {
  decodeTransferEncoding,
  extractAttachments,
  rawAttachmentFetch
} from "./attachments.js";
import { extractMessageLinks } from "./messageLinks.js";
import { parseCalendarInvite } from "./calendarInvite.js";
import { parseListUnsubscribe, readHeader } from "./listUnsubscribe.js";
import { MAX_HEADER_BYTES, boundMessageId, parseMessageIds } from "./threading.js";
import { detectImapCapabilities } from "./imapCapabilities.js";
import { createExistsQueue } from "./existsQueue.js";

export type { ImapSyncCursor } from "./imapSequenceRanges.js";
import type { ImapSyncCursor } from "./imapSequenceRanges.js";

export interface ImapSyncResult {
  uidValidity: string;
  // Newest UID that existed when the sync opened the mailbox.
  highestUid?: number;
}

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
      this.recordCapabilities(account, client);
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
    onBatch: (messages: IncomingMessageSummary[]) => Promise<void>,
    cursor?: ImapSyncCursor,
    // Runs on the fetching connection before any message is read; it may
    // return a new limit (a fresh import after the numbering changed).
    onMailboxOpened?: (uidValidity: string) => Promise<number | "all" | undefined>
  ): Promise<ImapSyncResult> {
    const initial = await this.withConnectionRetry(async () => {
      return this.withConnectedClient(account, async (client) => {
        const openedMailbox = await client.mailboxOpen(mailbox, {
          readOnly: true
        });
        const uidValidity = String(openedMailbox.uidValidity);
        const effectiveLimit = (await onMailboxOpened?.(uidValidity)) ?? limit;
        // A cursor from another numbering is dropped (see cursorUid).
        const afterUid = cursorUid(cursor, uidValidity);
        const uids = afterUid === undefined
          ? await this.searchLatestUids(client, openedMailbox.exists, effectiveLimit)
          : await this.searchUidsAfter(client, afterUid);
        const batches = newestFirstUidBatches(
          uids,
          batchLimit(afterUid, effectiveLimit)
        );
        const firstUids = batches.at(0);
        const newestSeen = uids.reduce(
          (newest, uid) => Math.max(newest, uid),
          afterUid ?? 0
        );

        return {
          rawUidValidity: openedMailbox.uidValidity,
          result: {
            uidValidity,
            highestUid: openedMailbox.uidNext
              ? Number(openedMailbox.uidNext) - 1
              : newestSeen || undefined
          },
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
          if (openedMailbox.uidValidity !== initial.rawUidValidity) {
            throw new Error("Mailbox UIDVALIDITY changed during import");
          }
          return this.fetchUids(client, account, mailbox, uids);
        });
      });

      if (batch.length > 0) {
        await onBatch(batch);
      }
    }
    return initial.result;
  }

  /** Re-reads headers of already stored messages (one connection, one mailbox). */
  async fetchSummariesByUid(
    account: MailAccount,
    mailbox: string,
    uids: number[]
  ): Promise<{ uidValidity: string; messages: IncomingMessageSummary[] }> {
    return this.withConnectionRetry(() =>
      this.withConnectedClient(account, async (client) => {
        const openedMailbox = await client.mailboxOpen(mailbox, { readOnly: true });
        return {
          // Callers compare this across batches: a changed UIDVALIDITY means the UIDs name other messages.
          uidValidity: String(openedMailbox.uidValidity),
          messages: uids.length === 0 ? [] : await this.fetchUids(client, account, mailbox, uids)
        };
      })
    );
  }

  // Searches the server, so messages that were never imported are found too.
  async search(
    account: MailAccount,
    query: SearchObject,
    limit = 50
  ): Promise<IncomingMessageSummary[]> {
    return this.withConnectedClient(account, async (client) => {
      await client.mailboxOpen("INBOX", { readOnly: true });
      const found = (await client.search(query, { uid: true })) || [];
      const newest = found.sort((a, b) => b - a).slice(0, limit);
      if (newest.length === 0) return [];
      const summaries = await this.fetchUids(client, account, "INBOX", newest);
      return summaries.sort(
        (a, b) => b.receivedAt.getTime() - a.receivedAt.getTime()
      );
    });
  }

  async fetchSummary(
    account: MailAccount,
    mailbox: string,
    providerMessageId: string
  ): Promise<IncomingMessageSummary | null> {
    const uid = Number(providerMessageId);
    if (!Number.isInteger(uid) || uid <= 0) return null;
    return this.withConnectedClient(account, async (client) => {
      await client.mailboxOpen(mailbox, { readOnly: true });
      const [summary] = await this.fetchUids(client, account, mailbox, [uid]);
      return summary ?? null;
    });
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
        {
          bodyStructure: true,
          envelope: true,
          headers: [
            "references",
            "list-unsubscribe",
            "list-unsubscribe-post",
            "authentication-results"
          ]
        },
        { uid: true }
      );
      if (!message || !message.bodyStructure) {
        throw new Error("Message body was not found on the IMAP server.");
      }
      const unsubscribe = unsubscribeFromHeaders(message.headers);
      const authenticationFailures = parseAuthenticationFailures(
        message.headers?.toString("utf8") ?? "",
        account.providerId
      );

      const attachments = extractAttachments(message.bodyStructure);
      const thread = toThreadHeaders(message);
      const bodyParts = selectBodyParts(message.bodyStructure);
      const invite = await this.fetchInvite(
        client,
        providerMessageId,
        message.bodyStructure
      );
      let htmlFallback: IncomingMessageContent | null = null;
      let htmlLinks: IncomingMessageLink[] = [];
      let rawHtml: string | undefined;

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
          if (text) {
            return {
              text,
              truncated,
              links: htmlLinks,
              html: rawHtml,
              attachments,
              thread,
              unsubscribe,
              authenticationFailures,
              invite
            };
          }
          continue;
        }

        // A truncated HTML part is incomplete: leave html empty so the client
        // shows the complete plain-text body instead.
        if (!truncated) rawHtml ??= decoded;
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
            links: htmlLinks,
            html: rawHtml,
            attachments,
            thread,
            authenticationFailures,
            invite
          };
        }
      }

      if (htmlFallback) {
        return { ...htmlFallback, links: htmlLinks, html: rawHtml, unsubscribe, invite };
      }
      // Image-only HTML has no extractable text but still needs html returned.
      if (rawHtml) {
        return {
          text: "",
          truncated: false,
          links: htmlLinks,
          html: rawHtml,
          attachments,
          thread,
          unsubscribe,
          authenticationFailures,
          invite
        };
      }
      return {
        text: "",
        truncated: false,
        links: [],
        attachments,
        thread,
        unsubscribe,
        authenticationFailures,
        invite
      };
    } finally {
      await client.logout().catch(() => undefined);
    }
  }

  async setFlags(
    account: MailAccount,
    mailbox: string,
    providerMessageId: string,
    change: MessageFlagChange
  ): Promise<void> {
    await this.withConnectedClient(account, async (client) => {
      await client.mailboxOpen(mailbox);
      const options = { uid: true };
      for (const [flag, value] of [
        ["\\Seen", change.seen],
        ["\\Flagged", change.flagged]
      ] as const) {
        if (value === undefined) continue;
        const apply = value ? client.messageFlagsAdd : client.messageFlagsRemove;
        await apply.call(client, providerMessageId, [flag], options);
      }
    });
  }

  async downloadAttachment(
    account: MailAccount,
    mailbox: string,
    providerMessageId: string,
    part: string
  ): Promise<AttachmentDownload | null> {
    const client = await this.createClient(account);
    await client.connect();
    const close = async () => {
      await client.logout().catch(() => undefined);
    };

    try {
      await client.mailboxOpen(mailbox, { readOnly: true });
      const message = await client.fetchOne(
        providerMessageId,
        { bodyStructure: true },
        { uid: true }
      );
      const attachment: IncomingMessageAttachment | undefined = message &&
        message.bodyStructure
        ? extractAttachments(message.bodyStructure).find(
            (item) => item.part === part
          )
        : undefined;
      if (!attachment) {
        await close();
        return null;
      }

      const raw = rawAttachmentFetch(
        (message as FetchMessageObject).bodyStructure!,
        part
      );
      if (raw) {
        // shortcut: buffers the whole text part in memory; stream it if large text attachments matter.
        const fetched = await client.fetchOne(
          providerMessageId,
          { bodyParts: [raw.key] },
          { uid: true }
        );
        const bytes = fetched ? fetched.bodyParts?.get(raw.key) : undefined;
        if (!bytes) {
          await close();
          return null;
        }
        return {
          filename: attachment.filename,
          contentType: attachment.contentType,
          stream: Readable.from([decodeTransferEncoding(bytes, raw.encoding)]),
          close
        };
      }

      const download = await client.download(providerMessageId, part, {
        uid: true
      });
      return {
        filename: attachment.filename,
        contentType: attachment.contentType,
        stream: download.content,
        close
      };
    } catch (error) {
      await close();
      throw error;
    }
  }

  async watch(
    account: MailAccount,
    mailbox: string,
    onMessage: (message: IncomingMessageSummary) => Promise<void>,
    onDisconnect?: (error: Error) => void
  ): Promise<() => Promise<void>> {
    if (!supportsImapIdle(account)) {
      const provider = getProvider(account.providerId);
      throw new Error(`${provider.displayName} does not support IMAP IDLE`);
    }

    const client = await this.createClient(account);
    let stopped = false;
    let disconnectReported = false;

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
      this.recordCapabilities(account, client);
      await client.mailboxOpen(mailbox);
    } catch (error) {
      stopped = true;
      await client.logout().catch(() => undefined);
      throw error;
    }

    const handleExists = createExistsQueue({
      fetchNewest: (count) => this.fetchLatest(account, mailbox, count),
      onMessage,
      onError: (error) => reportDisconnect(toError(error)),
      isStopped: () => stopped
    });
    client.on("exists", (event) => {
      void handleExists(event);
    });

    return async () => {
      stopped = true;
      await client.logout().catch(() => undefined);
    };
  }

  // A broken invite part must never hide the message body.
  private async fetchInvite(
    client: ImapFlow,
    uid: string,
    structure: MessageStructureObject
  ): Promise<CalendarInvite | undefined> {
    const part = findCalendarPart(structure);
    if (!part) return undefined;
    try {
      const download = await client.download(uid, part.part ?? "1", {
        uid: true,
        maxBytes: ImapReceiver.maxBodyBytes
      });
      const raw = await readBodyStream(download.content);
      return parseCalendarInvite(raw.toString("utf8")) ?? undefined;
    } catch {
      return undefined;
    }
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

  // Callers persist the account, so the result survives restarts.
  private recordCapabilities(account: MailAccount, client: ImapFlow): void {
    const detected = detectImapCapabilities(client.capabilities);
    // watch() refuses accounts without supportsImapIdle, so "idle" means IDLE is actually used.
    detected.idle &&= supportsImapIdle(account);
    account.incomingCapabilities = detected;
  }

  private async withConnectedClient<T>(
    account: MailAccount,
    operation: (client: ImapFlow) => Promise<T>
  ): Promise<T> {
    const client = await this.createClient(account);
    try {
      await client.connect();
      this.recordCapabilities(account, client);
      return await operation(client);
    } finally {
      await client.logout().catch(() => undefined);
    }
  }

  private async searchLatestUids(
    client: ImapFlow,
    exists: number,
    limit: number | "all"
  ): Promise<number[]> {
    const query = latestUidSearchQuery(exists, limit);
    if (!query) return [];
    return (await client.search(query, { uid: true })) || [];
  }

  private async searchUidsAfter(
    client: ImapFlow,
    afterUid: number
  ): Promise<number[]> {
    // "n:*" always matches the newest message even when its UID is below n.
    const uids = (await client.search({ uid: `${afterUid + 1}:*` }, { uid: true })) || [];
    return uids.filter((uid) => uid > afterUid);
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
      internalDate: true,
      uid: true,
      threadId: true,
      // classificationHeaderNames already includes list-unsubscribe.
      headers: [...classificationHeaderNames, "list-unsubscribe-post", "references"]
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

  const from = envelope.from?.map((item) => item.address).filter(Boolean).join(", ") ?? "";
  const headers = parseRawHeaders(message.headers?.subarray(0, MAX_HEADER_BYTES));
  return {
    accountId: account.id,
    providerMessageId: String(message.uid),
    mailbox,
    from,
    subject: envelope.subject ?? "",
    receivedAt: envelope.date instanceof Date ? envelope.date : new Date(),
    arrivedAt: message.internalDate instanceof Date ? message.internalDate : undefined,
    hasAttachments: false,
    unsubscribe: unsubscribeFromHeaders(message.headers),
    messageId: boundMessageId(envelope.messageId),
    inReplyTo: boundMessageId(envelope.inReplyTo),
    // Only the References value: List-Id/List-Unsubscribe also carry <...> tokens.
    references: parseMessageIds(headers["references"]),
    gmailThreadId: message.threadId,
    seen: message.flags?.has("\\Seen") ?? false,
    flagged: message.flags?.has("\\Flagged") ?? false,
    category: classifyMessage(headers, from)
  };
}

function toThreadHeaders(message: FetchMessageObject): MessageThreadHeaders {
  const envelope = message.envelope;
  const addresses = (list?: Array<{ address?: string }>) =>
    list?.map((item) => item.address).filter((a): a is string => Boolean(a)) ?? [];
  // Same bounded parsing as the stored summary fields (threading.ts).
  return {
    messageId: boundMessageId(envelope?.messageId),
    // Only the References value: List-Unsubscribe is fetched too and carries <...> tokens.
    references: parseMessageIds(
      parseRawHeaders(message.headers?.subarray(0, MAX_HEADER_BYTES))["references"]
    ),
    replyTo: addresses(envelope?.replyTo),
    to: addresses(envelope?.to),
    cc: addresses(envelope?.cc)
  };
}

function unsubscribeFromHeaders(headers: Buffer | undefined): ListUnsubscribe | null {
  const raw = headers?.toString("utf8") ?? "";
  return parseListUnsubscribe(
    readHeader(raw, "List-Unsubscribe"),
    readHeader(raw, "List-Unsubscribe-Post")
  ) ?? null;
}

function toError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
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

function findCalendarPart(
  part: MessageStructureObject
): MessageStructureObject | null {
  if (part.type.toLowerCase() === "text/calendar") return part;
  for (const child of part.childNodes ?? []) {
    const found = findCalendarPart(child);
    if (found) return found;
  }
  return null;
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
