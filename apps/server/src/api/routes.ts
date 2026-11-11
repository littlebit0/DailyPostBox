import type { FastifyInstance } from "fastify";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import type { MailSender } from "../mail/MailSender.js";
import type {
  AuthMode,
  IncomingMessageContent,
  IncomingMessageSummary,
  MailAccount,
  MailProtocol,
  OutgoingMessageDraft,
  ProviderId
} from "../domain/types.js";
import type { AccountRepository } from "../workers/AccountRepository.js";
import { providerRegistry } from "../providers/providerRegistry.js";
import {
  applySyncFailure,
  isAuthenticationFailure
} from "../mail/authenticationFailure.js";

const sendSchema = z.object({
  accountId: z.string(),
  to: z.array(z.string().email()).min(1),
  cc: z.array(z.string().email()).optional(),
  bcc: z.array(z.string().email()).optional(),
  subject: z.string().default(""),
  html: z.string().optional(),
  text: z.string().optional()
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
});

const demoUserId = "demo-user";

export async function registerRoutes(
  app: FastifyInstance,
  deps: {
    sender: MailSender;
    accounts: AccountRepository;
    validateAccount: (account: MailAccount) => Promise<void>;
    fetchMessageContent: (
      account: MailAccount,
      message: IncomingMessageSummary
    ) => Promise<IncomingMessageContent>;
    startAccountSync: (account: MailAccount) => Promise<void>;
    stopAccountSync: (accountId: string) => Promise<void>;
  }
): Promise<void> {
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
    await deps.stopAccountSync(params.id);
    await deps.accounts.deleteAccount(params.id);
    return reply.code(204).send();
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
    return messages
      .filter((message) => message.accountId === params.id)
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
    const message = messages.find(
      (item) => item.accountId === params.accountId &&
        item.providerMessageId === params.messageId
    );
    if (!message) {
      return reply.code(404).send({ error: "Message not found" });
    }

    const content = await deps.fetchMessageContent(account, message);

    return {
      ...message,
      id: message.providerMessageId,
      receivedAt: message.receivedAt.toISOString(),
      body: content.text,
      bodyTruncated: content.truncated,
      bodyLinks: content.links
    };
  });

  app.get("/mail/inbox", async () => {
    const messages = await deps.accounts.listInbox(demoUserId);
    return messages.map((message) => ({
      ...message,
      id: message.providerMessageId,
      receivedAt: message.receivedAt.toISOString()
    }));
  });

  app.get("/mail/messages/:id", async (request, reply) => {
    const params = z.object({ id: z.string() }).parse(request.params);
    const message = await deps.accounts.getMessage(demoUserId, params.id);

    if (!message) {
      return reply.code(404).send({ error: "Message not found" });
    }
    const account = await deps.accounts.getAccount(message.accountId);
    if (!account || account.userId !== demoUserId) {
      return reply.code(404).send({ error: "Account not found" });
    }
    const content = await deps.fetchMessageContent(account, message);

    return {
      ...message,
      id: message.providerMessageId,
      receivedAt: message.receivedAt.toISOString(),
      body: content.text,
      bodyTruncated: content.truncated,
      bodyLinks: content.links
    };
  });

  app.post("/mail/send", async (request, reply) => {
    const draft = sendSchema.parse(request.body) as OutgoingMessageDraft;
    const account = await deps.accounts.getAccount(draft.accountId);

    if (!account) {
      return reply.code(404).send({ error: "Account not found" });
    }

    const result = await deps.sender.send(account, draft);
    return reply.code(202).send(result);
  });

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
