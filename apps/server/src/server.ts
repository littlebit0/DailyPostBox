import Fastify from "fastify";
import cors from "@fastify/cors";
import { env } from "./config/env.js";
import { DevelopmentSecretResolver } from "./security/SecretResolver.js";
import { ImapReceiver } from "./mail/ImapReceiver.js";
import { Pop3Receiver } from "./mail/Pop3Receiver.js";
import { SmtpSender } from "./mail/SmtpSender.js";
import { NoopPushNotifier } from "./notifications/PushNotifier.js";
import { InMemoryAccountRepository } from "./workers/AccountRepository.js";
import { MailSyncWorker } from "./workers/MailSyncWorker.js";
import { registerRoutes } from "./api/routes.js";
import { OAuthAccountFlow } from "./auth/OAuthAccountFlow.js";

const app = Fastify({
  logger: true
});

await app.register(cors, {
  origin: true
});

const secrets = new DevelopmentSecretResolver();
const accounts = new InMemoryAccountRepository();
const imap = new ImapReceiver(secrets);
const pop3 = new Pop3Receiver();
const sender = new SmtpSender(secrets);
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
  startAccountSync: async (account) => worker.startAccount(account)
}).register(app);

app.setErrorHandler((error, _request, reply) => {
  app.log.error(error);
  const fastifyError = error as { statusCode?: number; message?: string };
  const statusCode = typeof fastifyError.statusCode === "number" &&
    fastifyError.statusCode >= 400
    ? fastifyError.statusCode
    : 500;
  const message = statusCode >= 500
    ? "메일 서버 연결에 실패했습니다. 로그인 방식과 제공자 설정을 확인하세요."
    : fastifyError.message
      ? fastifyError.message
      : "요청을 처리하지 못했습니다.";
  return reply.code(statusCode).send({ error: message });
});

app.addHook("onReady", async () => {
  await worker.start();
});

app.addHook("onClose", async () => {
  await worker.stop();
});

await app.listen({
  port: env.PORT,
  host: env.HOST
});
