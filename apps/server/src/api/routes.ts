import type { FastifyInstance, FastifyRequest } from "fastify";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import type { SearchObject } from "imapflow";
import type { MailSender } from "../mail/MailSender.js";
import { withThreadInfo } from "../mail/threading.js";
import {
  SendQueue,
  SendQueueFullError,
  defaultUndoDelaySeconds,
  undoDelaySeconds
} from "../mail/SendQueue.js";
import type {
  AttachmentDownload,
  AuthMode,
  IncomingMessageContent,
  IncomingMessageSummary,
  MailAccount,
  MessageFlagChange,
  MailProtocol,
  OutgoingMessageDraft,
  ProviderId
} from "../domain/types.js";
import type { AccountRepository } from "../workers/AccountRepository.js";
import type { RevokeResult } from "../auth/OAuthTokenRevoker.js";
import type { SnoozeStore } from "../workers/SnoozeStore.js";
import { sanitizeHtml } from "../mail/safeHtml.js";
import { replyFields } from "../mail/replyRecipients.js";
import { providerRegistry } from "../providers/providerRegistry.js";
import {
  applySyncFailure,
  isAuthenticationFailure
} from "../mail/authenticationFailure.js";
import {
  SearchQueryError,
  parseSearchQuery,
  toImapSearch
} from "../mail/searchQuery.js";

const sendSchema = z.object({
  accountId: z.string(),
  to: z.array(z.string().email()).min(1),
  cc: z.array(z.string().email()).optional(),
  bcc: z.array(z.string().email()).optional(),
  subject: z.string().default(""),
  html: z.string().optional(),
  text: z.string().optional(),
  delaySeconds: z
    .number()
    .refine((value) => (undoDelaySeconds as readonly number[]).includes(value), {
      message: `delaySeconds must be one of ${undoDelaySeconds.join(", ")}`
    })
    .default(defaultUndoDelaySeconds),
  inReplyTo: z.string().regex(/^<[^<>\s]+>$/).optional(),
  references: z.array(z.string().regex(/^<[^<>\s]+>$/)).optional()
});

const pushTokenSchema = z.object({
  platform: z.enum(["ios", "android", "macos", "windows", "web"]),
  token: z.string().min(1)
});

const accountSchema = z.object({
  providerId: z.enum(["gmail", "outlook", "naver", "daum", "custom"]),
  emailAddress: z.string().email(),
  displayName: z.string().optional(),
  authMode: z.enum(["oauth2", "password", "app-password"]),
  incomingProtocol: z.enum(["imap", "pop3"]),
  secret: z.string().min(1),
  initialSync: z.object({
    includePreviousMessages: z.boolean(),
    limit: z.union([z.number().int().positive(), z.literal("all")])
  }).default({
    includePreviousMessages: true,
    limit: 100
  }),
  connectionOverride: z.object({
    incoming: z.object({
      host: z.string().min(1),
      port: z.number().int().positive(),
      secure: z.boolean(),
      supportsIdle: z.boolean().optional()
    }).optional(),
    outgoing: z.object({
      host: z.string().min(1),
      port: z.number().int().positive(),
      secure: z.boolean()
    }).optional()
  }).optional()
}).superRefine((account, context) => {
  const provider = providerRegistry[account.providerId];
  if (!provider.authModes.includes(account.authMode)) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["authMode"],
      message: `${provider.displayName} does not support ${account.authMode} authentication.`
    });
  }
  // The custom provider has no default host to fall back on.
  if (account.providerId === "custom" &&
    (!account.connectionOverride?.incoming || !account.connectionOverride.outgoing)) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["connectionOverride"],
      message: "사용자 지정 메일 서버는 수신(IMAP)·발신(SMTP) 서버 주소와 포트가 필요합니다."
    });
  }
});

const demoUserId = "demo-user";

// shortcut: no real auth yet (issue #20), so mail search, the IMAP fallback
// and attachment downloads require a loopback peer, a loopback Host (blocks
// DNS rebinding) and no Origin header (browsers send one, the native client
// does not), unless their opt-out flag is "true".
function isLocalMailRequest(
  request: FastifyRequest,
  optOutFlag: "ALLOW_REMOTE_MAIL_SEARCH" | "ALLOW_REMOTE_MAIL_ACCESS"
): boolean {
  if (process.env[optOutFlag] === "true") return true;
  const host = (request.headers.host ?? "").replace(/:\d+$/, "").toLowerCase();
  return ["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(request.ip) &&
    ["127.0.0.1", "localhost", "[::1]"].includes(host) &&
    request.headers.origin === undefined;
}

function canReadUnstoredMail(request: FastifyRequest): boolean {
  return isLocalMailRequest(request, "ALLOW_REMOTE_MAIL_SEARCH");
}

function canReadAttachments(request: FastifyRequest): boolean {
  return isLocalMailRequest(request, "ALLOW_REMOTE_MAIL_ACCESS");
}

export async function registerRoutes(
  app: FastifyInstance,
  deps: {
    revokeOAuthTokens?: (account: MailAccount) => Promise<RevokeResult>;
    sender: MailSender;
    sendQueue?: SendQueue;
    accounts: AccountRepository;
    snoozes: SnoozeStore;
    validateAccount: (account: MailAccount) => Promise<void>;
    fetchMessageContent: (
      account: MailAccount,
      message: IncomingMessageSummary
    ) => Promise<IncomingMessageContent>;
    setMessageFlags: (
      account: MailAccount,
      message: IncomingMessageSummary,
      change: MessageFlagChange
    ) => Promise<void>;
    downloadAttachment: (
      account: MailAccount,
      message: IncomingMessageSummary,
      part: string
    ) => Promise<AttachmentDownload | null>;
    searchMessages: (
      account: MailAccount,
      query: SearchObject
    ) => Promise<IncomingMessageSummary[]>;
    fetchMessageSummary: (
      account: MailAccount,
      providerMessageId: string
    ) => Promise<IncomingMessageSummary | null>;
    startAccountSync: (account: MailAccount) => Promise<void>;
    resumeAccountSync: (account: MailAccount) => Promise<void>;
    stopAccountSync: (accountId: string) => Promise<void>;
  }
): Promise<void> {
  // Messages synced before unsubscribe parsing have no value yet; the UID
  // cursor never refetches them, so fill it from the detail fetch once.
  async function backfillUnsubscribe(
    message: IncomingMessageSummary,
    content: IncomingMessageContent
  ): Promise<IncomingMessageSummary> {
    if (message.unsubscribe !== undefined || content.unsubscribe === undefined) {
      return message;
    }
    const updated = { ...message, unsubscribe: content.unsubscribe };
    await deps.accounts.saveIncomingMessage(updated);
    return updated;
  }
  // Hides pending snoozes and floats woken messages to the top.
  const visibleMessages = (messages: IncomingMessageSummary[]) => messages
    .filter((message) => !deps.snoozes.isHidden(message.accountId, message.providerMessageId))
    .sort((a, b) =>
      deps.snoozes.sortTime(b.accountId, b.providerMessageId, b.receivedAt) -
      deps.snoozes.sortTime(a.accountId, a.providerMessageId, a.receivedAt)
    );
  const sendQueue =
    deps.sendQueue ??
    new SendQueue(deps.sender, (error) => app.log.error({ err: error }, "mail send failed"));

  app.get("/health", async () => ({ ok: true }));

  app.get("/providers", async () => {
    return Object.values(providerRegistry).map((provider) => ({
      id: provider.id,
      displayName: provider.displayName,
      authModes: provider.authModes,
      incoming: provider.incoming,
      outgoing: provider.outgoing,
      supportsOAuth: Boolean(provider.oauth)
    }));
  });

  app.get("/accounts", async () => {
    const accounts = await deps.accounts.listActiveAccounts();
    return accounts
      .filter((account) => account.userId === demoUserId)
      .map(({ encryptedSecretRef: _secret, ...account }) => account);
  });

  app.post("/accounts", async (request, reply) => {
    const body = accountSchema.parse(request.body);
    const now = new Date();
    const account: MailAccount = {
      id: randomUUID(),
      userId: demoUserId,
      providerId: body.providerId as ProviderId,
      emailAddress: body.emailAddress,
      displayName: body.displayName,
      authMode: body.authMode as AuthMode,
      incomingProtocol: body.incomingProtocol as MailProtocol,
      encryptedSecretRef: body.secret,
      syncStatus: "validating",
      initialSync: body.initialSync,
      connectionOverride: body.connectionOverride,
      createdAt: now,
      updatedAt: now
    };

    await deps.validateAccount(account);
    account.syncStatus = "syncing";
    await deps.accounts.addAccount(account);
    void deps.startAccountSync(account);

    const { encryptedSecretRef: _secret, ...publicAccount } = account;
    return reply.code(201).send(publicAccount);
  });

  app.post("/accounts/validate", async (request) => {
    const body = accountSchema.parse(request.body);
    const now = new Date();
    const account: MailAccount = {
      id: "validation-preview",
      userId: demoUserId,
      providerId: body.providerId as ProviderId,
      emailAddress: body.emailAddress,
      displayName: body.displayName,
      authMode: body.authMode as AuthMode,
      incomingProtocol: body.incomingProtocol as MailProtocol,
      encryptedSecretRef: body.secret,
      syncStatus: "validating",
      initialSync: body.initialSync,
      connectionOverride: body.connectionOverride,
      createdAt: now,
      updatedAt: now
    };

    await deps.validateAccount(account);
    return { ok: true };
  });

  app.delete("/accounts/:id", async (request, reply) => {
    const params = z.object({ id: z.string() }).parse(request.params);
    const account = await deps.accounts.getAccount(params.id);
    if (!account || account.userId !== demoUserId) {
      return reply.code(404).send({ error: "Account not found" });
    }
    await deps.stopAccountSync(params.id);
    const revoke = deps.revokeOAuthTokens
      ? await deps.revokeOAuthTokens(account)
      : "skipped";
    await deps.accounts.deleteAccount(params.id);
    await deps.snoozes.removeAccount(params.id);
    return { revoke };
  });

  app.put("/accounts/:id/signature", async (request, reply) => {
    const params = z.object({ id: z.string() }).parse(request.params);
    const body = z.object({ signature: z.string().max(2000) }).parse(request.body);
    const account = await deps.accounts.getAccount(params.id);

    if (!account || account.userId !== demoUserId) {
      return reply.code(404).send({ error: "Account not found" });
    }

    const signature = body.signature.trim();
    account.signature = signature || undefined;
    account.updatedAt = new Date();
    await deps.accounts.updateAccount(account);

    const { encryptedSecretRef: _secret, ...publicAccount } = account;
    return publicAccount;
  });

  app.patch("/accounts/:id/notifications", async (request, reply) => {
    const params = z.object({ id: z.string() }).parse(request.params);
    const body = z.object({ enabled: z.boolean() }).parse(request.body);
    const account = await deps.accounts.getAccount(params.id);

    if (!account || account.userId !== demoUserId) {
      return reply.code(404).send({ error: "Account not found" });
    }

    account.notificationsEnabled = body.enabled;
    account.updatedAt = new Date();
    await deps.accounts.updateAccount(account);

    const { encryptedSecretRef: _secret, ...publicAccount } = account;
    return publicAccount;
  });

  app.post("/accounts/:id/validate", async (request, reply) => {
    const params = z.object({ id: z.string() }).parse(request.params);
    const account = await deps.accounts.getAccount(params.id);

    if (!account) {
      return reply.code(404).send({ error: "Account not found" });
    }

    account.syncStatus = "validating";
    account.syncError = undefined;
    account.syncErrorCode = undefined;
    await deps.accounts.updateAccount(account);

    try {
      await deps.validateAccount(account);
      account.syncStatus = "idle";
      account.updatedAt = new Date();
      await deps.accounts.updateAccount(account);
      // An authentication failure stops the watcher; a passing check must
      // start it again or the account looks healthy but receives no mail.
      void deps.resumeAccountSync(account);
    } catch (error) {
      applySyncFailure(account, error);
      account.updatedAt = new Date();
      await deps.accounts.updateAccount(account);
      throw error;
    }

    const { encryptedSecretRef: _secret, ...publicAccount } = account;
    return publicAccount;
  });

  // Replaces a password or app password while keeping the account's stored
  // mail and settings. The old secret stays if the new one fails to connect.
  app.put("/accounts/:id/credentials", async (request, reply) => {
    const params = z.object({ id: z.string() }).parse(request.params);
    const body = z.object({ secret: z.string().min(1) }).parse(request.body);
    const account = await deps.accounts.getAccount(params.id);

    if (!account || account.userId !== demoUserId) {
      return reply.code(404).send({ error: "Account not found" });
    }
    if (account.authMode === "oauth2") {
      return reply.code(400).send({
        error: "브라우저 로그인 계정은 브라우저에서 다시 로그인하세요."
      });
    }

    try {
      await deps.validateAccount({ ...account, encryptedSecretRef: body.secret });
    } catch (error) {
      if (isAuthenticationFailure(error)) {
        return reply.code(400).send({
          error: credentialFailureMessage(account, error)
        });
      }
      throw error;
    }

    await deps.stopAccountSync(account.id);
    account.encryptedSecretRef = body.secret;
    account.syncStatus = "syncing";
    account.syncError = undefined;
    account.syncErrorCode = undefined;
    account.updatedAt = new Date();
    await deps.accounts.updateAccount(account);
    void deps.startAccountSync(account);

    const { encryptedSecretRef: _secret, ...publicAccount } = account;
    return publicAccount;
  });

  app.post("/accounts/:id/sync", async (request, reply) => {
    const params = z.object({ id: z.string() }).parse(request.params);
    const account = await deps.accounts.getAccount(params.id);

    if (!account) {
      return reply.code(404).send({ error: "Account not found" });
    }

    account.syncStatus = "syncing";
    account.syncError = undefined;
    account.syncErrorCode = undefined;
    await deps.accounts.updateAccount(account);
    void deps.startAccountSync(account);

    const { encryptedSecretRef: _secret, ...publicAccount } = account;
    return publicAccount;
  });

  app.get("/accounts/:id/messages", async (request, reply) => {
    const params = z.object({ id: z.string() }).parse(request.params);
    const account = await deps.accounts.getAccount(params.id);

    if (!account || account.userId !== demoUserId) {
      return reply.code(404).send({ error: "Account not found" });
    }

    const messages = await deps.accounts.listInbox(demoUserId);
    return withThreadInfo(
      visibleMessages(messages.filter((message) => message.accountId === params.id))
    ).map((message) => ({
        ...message,
        id: message.providerMessageId,
        receivedAt: message.receivedAt.toISOString(),
        ...flagState(message)
      }));
  });

  app.get("/accounts/:id/threads/:threadId", async (request, reply) => {
    const params = z.object({ id: z.string(), threadId: z.string() })
      .parse(request.params);
    const account = await deps.accounts.getAccount(params.id);

    if (!account || account.userId !== demoUserId) {
      return reply.code(404).send({ error: "Account not found" });
    }

    const messages = await deps.accounts.listInbox(demoUserId);
    return withThreadInfo(
      visibleMessages(messages.filter((message) => message.accountId === params.id))
    )
      .filter((message) => message.threadId === params.threadId)
      .sort((a, b) => a.receivedAt.getTime() - b.receivedAt.getTime())
      .map((message) => ({
        ...message,
        id: message.providerMessageId,
        receivedAt: message.receivedAt.toISOString(),
        ...flagState(message)
      }));
  });

  app.get("/accounts/:id/search", async (request, reply) => {
    if (!canReadUnstoredMail(request)) {
      return reply.code(403).send({ error: "Search is only available locally." });
    }
    const params = z.object({ id: z.string() }).parse(request.params);
    const { q } = z.object({ q: z.string().max(500) }).parse(request.query);
    const account = await deps.accounts.getAccount(params.id);

    if (!account || account.userId !== demoUserId) {
      return reply.code(404).send({ error: "Account not found" });
    }
    if (account.incomingProtocol !== "imap") {
      return reply.code(400).send({ error: "Search needs an IMAP account." });
    }

    let query: SearchObject;
    try {
      query = toImapSearch(parseSearchQuery(q));
    } catch (error) {
      if (error instanceof SearchQueryError) {
        return reply.code(400).send({ error: error.message });
      }
      throw error;
    }

    const messages = await deps.searchMessages(account, query);
    return messages
      .filter((message) => !deps.snoozes.isHidden(message.accountId, message.providerMessageId))
      .map((message) => ({
      ...message,
      id: message.providerMessageId,
      receivedAt: message.receivedAt.toISOString()
    }));
  });

  app.get("/accounts/:accountId/messages/:messageId", async (request, reply) => {
    const params = z.object({
      accountId: z.string(),
      messageId: z.string()
    }).parse(request.params);
    const account = await deps.accounts.getAccount(params.accountId);

    if (!account || account.userId !== demoUserId) {
      return reply.code(404).send({ error: "Account not found" });
    }

    const messages = await deps.accounts.listInbox(demoUserId);
    const stored = messages.find(
      (item) => item.accountId === params.accountId &&
        item.providerMessageId === params.messageId
    );
    // Search results can point at mail that was never imported.
    const fetched = stored ?? (account.incomingProtocol === "imap" && canReadUnstoredMail(request)
      ? await deps.fetchMessageSummary(account, params.messageId)
      : null);
    if (!fetched) {
      return reply.code(404).send({ error: "Message not found" });
    }

    const content = await deps.fetchMessageContent(account, fetched);
    // Only stored mail is backfilled; saving a search-only result would import it.
    const message = stored ? await backfillUnsubscribe(stored, content) : fetched;

    return {
      ...message,
      id: message.providerMessageId,
      receivedAt: message.receivedAt.toISOString(),
      ...flagState(message),
      body: content.text,
      bodyTruncated: content.truncated,
      bodyLinks: content.links,
      invite: content.invite ?? null,
      authenticationFailures: content.authenticationFailures ?? [],
      attachments: content.attachments,
      ...replyFields(message, content, account),
      ...safeHtmlFields(content, request.query)
    };
  });

  app.post("/accounts/:accountId/messages/:messageId/flags", async (request, reply) => {
    const params = z.object({
      accountId: z.string(),
      messageId: z.string()
    }).parse(request.params);
    const change = z.object({
      seen: z.boolean().optional(),
      flagged: z.boolean().optional()
    }).refine((value) => value.seen !== undefined || value.flagged !== undefined, {
      message: "seen or flagged is required."
    }).parse(request.body);
    const account = await deps.accounts.getAccount(params.accountId);

    if (!account || account.userId !== demoUserId) {
      return reply.code(404).send({ error: "Account not found" });
    }
    const messages = await deps.accounts.listInbox(demoUserId);
    const message = messages.find(
      (item) => item.accountId === params.accountId &&
        item.providerMessageId === params.messageId
    );
    if (!message) {
      return reply.code(404).send({ error: "Message not found" });
    }

    // Server first: the local copy only changes once the mail server accepted it.
    await deps.setMessageFlags(account, message, change);
    await deps.accounts.updateMessageFlags(
      params.accountId,
      params.messageId,
      change
    );
    return flagState({ ...message, ...change });
  });

  app.get(
    "/accounts/:accountId/messages/:messageId/attachments/:part",
    async (request, reply) => {
      if (!canReadAttachments(request)) {
        return reply.code(403).send({ error: "Attachments are only available locally." });
      }
      const params = z.object({
        accountId: z.string(),
        messageId: z.string(),
        part: z.string().regex(/^\d+(\.\d+)*$/)
      }).parse(request.params);
      const account = await deps.accounts.getAccount(params.accountId);

      if (!account || account.userId !== demoUserId) {
        return reply.code(404).send({ error: "Account not found" });
      }

      const messages = await deps.accounts.listInbox(demoUserId);
      // Search results can point at mail that was never imported; this route
      // is already local-only, and canReadUnstoredMail keeps the search gate.
      const message = messages.find(
        (item) => item.accountId === params.accountId &&
          item.providerMessageId === params.messageId
      ) ?? (account.incomingProtocol === "imap" && canReadUnstoredMail(request)
        ? await deps.fetchMessageSummary(account, params.messageId)
        : null);
      if (!message) {
        return reply.code(404).send({ error: "Message not found" });
      }

      const download = await deps.downloadAttachment(
        account,
        message,
        params.part
      );
      if (!download) {
        return reply.code(404).send({ error: "Attachment not found" });
      }

      const closeOnce = () => void download.close();
      reply.raw.once("close", closeOnce);
      download.stream.once("error", closeOnce);
      download.stream.once("end", closeOnce);
      return reply
        .header("Content-Type", download.contentType)
        .header(
          "Content-Disposition",
          `attachment; filename*=UTF-8''${encodeURIComponent(download.filename)}`
        )
        .send(download.stream);
    }
  );

  app.get("/mail/inbox", async () => {
    const messages = await deps.accounts.listInbox(demoUserId);
    return visibleMessages(messages).map((message) => ({
      ...message,
      id: message.providerMessageId,
      receivedAt: message.receivedAt.toISOString(),
      ...flagState(message)
    }));
  });

  // Snooze only hides the message inside DailyPostBox; the mail server is untouched.
  app.post("/accounts/:accountId/messages/:messageId/snooze", async (request, reply) => {
    const params = z.object({
      accountId: z.string(),
      messageId: z.string()
    }).parse(request.params);
    const body = z.object({ wakeAt: z.string().datetime({ offset: true }) }).parse(request.body);
    const wakeAt = new Date(body.wakeAt);
    if (wakeAt.getTime() <= Date.now()) {
      return reply.code(400).send({ error: "다시 알림 시각은 현재보다 이후여야 합니다." });
    }
    const messages = await deps.accounts.listInbox(demoUserId);
    const exists = messages.some(
      (item) => item.accountId === params.accountId &&
        item.providerMessageId === params.messageId
    );
    if (!exists) {
      return reply.code(404).send({ error: "Message not found" });
    }
    const entry = await deps.snoozes.snooze(params.accountId, params.messageId, wakeAt);
    return reply.code(200).send({ wakeAt: entry.wakeAt });
  });

  app.delete("/accounts/:accountId/messages/:messageId/snooze", async (request, reply) => {
    const params = z.object({
      accountId: z.string(),
      messageId: z.string()
    }).parse(request.params);
    await deps.snoozes.cancel(params.accountId, params.messageId);
    return reply.code(204).send();
  });

  // 10 MiB: explicit cap on the send body (Fastify default is 1 MiB).
  app.post("/mail/send", { bodyLimit: 10 * 1024 * 1024 }, async (request, reply) => {
    const { delaySeconds, ...parsed } = sendSchema.parse(request.body);
    const draft = parsed as OutgoingMessageDraft;
    const account = await deps.accounts.getAccount(draft.accountId);

    if (!account) {
      return reply.code(404).send({ error: "Account not found" });
    }

    let queued: { id: string; sendAt: Date };
    try {
      queued = sendQueue.enqueue(account, draft, delaySeconds);
    } catch (error) {
      if (error instanceof SendQueueFullError) {
        return reply.code(429).send({ error: "Too many pending sends" });
      }
      throw error;
    }
    return reply
      .code(202)
      .send({ id: queued.id, delaySeconds, sendAt: queued.sendAt.toISOString(), now: new Date().toISOString() });
  });

  app.get("/mail/send/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    const info = sendQueue.status(id);
    if (!info) return reply.code(404).send({ error: "Send request not found" });
    return info;
  });

  app.post("/mail/send/:id/cancel", async (request, reply) => {
    const { id } = request.params as { id: string };
    const status = sendQueue.cancel(id);

    if (!status) {
      return reply.code(404).send({ error: "Send request not found" });
    }
    if (status !== "cancelled") {
      return reply.code(409).send({ error: "Message already sent", status });
    }
    return reply.code(200).send({ id, status });
  });

  // Sends the mailto: unsubscribe request stored from the message's own
  // List-Unsubscribe header; the client never supplies the recipient.
  app.post(
    "/accounts/:accountId/messages/:messageId/unsubscribe",
    async (request, reply) => {
      const params = z.object({
        accountId: z.string(),
        messageId: z.string()
      }).parse(request.params);
      const account = await deps.accounts.getAccount(params.accountId);
      if (!account || account.userId !== demoUserId) {
        return reply.code(404).send({ error: "Account not found" });
      }

      const message = (await deps.accounts.listInbox(demoUserId)).find(
        (item) => item.accountId === params.accountId &&
          item.providerMessageId === params.messageId
      );
      if (!message) {
        return reply.code(404).send({ error: "Message not found" });
      }
      const mailto = message.unsubscribe?.mailto;
      if (!mailto) {
        return reply.code(400).send({ error: "No mailto unsubscribe address" });
      }

      await deps.sender.send(account, {
        accountId: account.id,
        to: [mailto.address],
        subject: mailto.subject ?? "unsubscribe",
        text: mailto.body ?? "unsubscribe"
      });
      return reply.code(202).send({ ok: true });
    }
  );

  app.post("/devices/push-token", async (request, reply) => {
    const body = pushTokenSchema.parse(request.body);

    await deps.accounts.savePushTarget({
      userId: demoUserId,
      platform: body.platform,
      deviceToken: body.token
    });

    return reply.code(202).send({ ok: true });
  });
}

// The mail server's own reply (never the secret) tells IMAP from SMTP
// rejections apart; Naver also needs IMAP enabled and an app password.
// Remote images stay blocked unless the client asks with ?remoteImages=allow.
function safeHtmlFields(content: IncomingMessageContent, query: unknown) {
  if (!content.html) return { html: "", remoteImageCount: 0 };
  const allowRemoteImages =
    (query as { remoteImages?: unknown } | null)?.remoteImages === "allow";
  const { html, remoteImageCount } = sanitizeHtml(content.html, { allowRemoteImages });
  return { html: html.trim() ? html : "", remoteImageCount };
}

function credentialFailureMessage(account: MailAccount, error: unknown): string {
  const detail = error as { responseText?: unknown; response?: unknown };
  const serverReply = typeof detail.responseText === "string"
    ? `IMAP: ${detail.responseText}`
    : typeof detail.response === "string"
      ? `SMTP: ${detail.response}`
      : undefined;
  const parts = ["로그인 정보가 올바르지 않습니다."];
  if (account.providerId === "naver") {
    parts.push(
      "네이버 메일 환경설정에서 IMAP/SMTP 사용을 켜고, 2단계 인증을 쓰면 애플리케이션 비밀번호(영문·숫자 12자리)를 입력하세요."
    );
  }
  if (serverReply) parts.push(`(${serverReply})`);
  return parts.join(" ");
}

function flagState(message: IncomingMessageSummary) {
  return { seen: message.seen ?? false, flagged: message.flagged ?? false };
}
