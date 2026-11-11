import Fastify from "fastify";
import cors from "@fastify/cors";
import { fileURLToPath } from "node:url";
import { ZodError } from "zod";
import { env } from "./config/env.js";
import { DevelopmentSecretResolver } from "./security/SecretResolver.js";
import { ImapReceiver } from "./mail/ImapReceiver.js";
import { Pop3Receiver } from "./mail/Pop3Receiver.js";
import { SmtpSender } from "./mail/SmtpSender.js";
import { NoopPushNotifier } from "./notifications/PushNotifier.js";
import { InMemoryAccountRepository } from "./workers/AccountRepository.js";
import type { AccountRepository } from "./workers/AccountRepository.js";
import { LocalFileAccountRepository } from "./workers/LocalFileAccountRepository.js";
import { MailSyncWorker } from "./workers/MailSyncWorker.js";
import { registerRoutes } from "./api/routes.js";
import { OAuthAccountFlow } from "./auth/OAuthAccountFlow.js";
import { OAuthTokenManager } from "./auth/OAuthTokenManager.js";

const app = Fastify({
  logger: true
});

await app.register(cors, {
  origin: true
});

const secrets = new DevelopmentSecretResolver();
const localDataPath = env.DATA_FILE_PATH ?? (
  process.env.NODE_ENV === "production"
    ? undefined
    : fileURLToPath(new URL("../.data/local-state.json", import.meta.url))
);
const accounts: AccountRepository = localDataPath
  ? new LocalFileAccountRepository(localDataPath)
  : new InMemoryAccountRepository();
const oauthTokens = new OAuthTokenManager(secrets, accounts);
const imap = new ImapReceiver(secrets, oauthTokens);
const pop3 = new Pop3Receiver();
const sender = new SmtpSender(secrets, oauthTokens);
const push = new NoopPushNotifier();

const worker = new MailSyncWorker(accounts, imap, pop3, push, {
  mailbox: "INBOX",
  pop3PollIntervalMs: 60_000,
  imapReconnectBaseDelayMs: 1_000,
  imapReconnectMaxDelayMs: 60_000
});

await registerRoutes(app, {
  sender,
  accounts,
  validateAccount: async (account) => {
    if (account.incomingProtocol === "imap") {
      await imap.testConnection(account);
    } else {
      await pop3.testConnection(account);
    }
    await sender.testConnection(account);
  },
  fetchMessageContent: async (account, message) => {
    const receiver = account.incomingProtocol === "imap" ? imap : pop3;
    return receiver.fetchMessageContent(
      account,
      message.mailbox,
      message.providerMessageId
    );
  },
  startAccountSync: async (account) => worker.startAccount(account),
  stopAccountSync: async (accountId) => worker.stopAccount(accountId)
});

new OAuthAccountFlow({
  accounts,
  validateAccount: async (account) => {
    if (account.incomingProtocol === "imap") {
      await imap.testConnection(account);
    } else {
      await pop3.testConnection(account);
    }
    await sender.testConnection(account);
  },
  startAccountSync: async (account) => worker.startAccount(account),
  stopAccountSync: async (accountId) => worker.stopAccount(accountId)
}).register(app);

app.setErrorHandler((error, _request, reply) => {
  app.log.error(error);
  const fastifyError = error as { statusCode?: number; message?: string };
  const statusCode = error instanceof ZodError
    ? 400
    : typeof fastifyError.statusCode === "number" && fastifyError.statusCode >= 400
      ? fastifyError.statusCode
      : 500;
  const message = error instanceof ZodError
    ? error.issues.map((issue) => issue.message).join(" ")
    : statusCode >= 500
      ? "메일 서버 연결에 실패했습니다. 로그인 방식과 제공자 설정을 확인하세요."
      : fastifyError.message
        ? fastifyError.message
        : "요청을 처리하지 못했습니다.";
  return reply.code(statusCode).send({ error: message });
});

app.addHook("onReady", () => {
  void worker.start().catch((error: unknown) => {
    app.log.error(error, "Failed to start mail sync workers");
  });
});

app.addHook("onClose", async () => {
  await worker.stop();
});

await app.listen({
  port: env.PORT,
  host: env.HOST
});
