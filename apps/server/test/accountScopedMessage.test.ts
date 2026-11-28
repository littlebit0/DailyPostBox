import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import type { MailAccount } from "../src/domain/types.js";
import { registerRoutes } from "../src/api/routes.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";

function account(id: string): MailAccount {
  const now = new Date();
  return {
    id,
    userId: "demo-user",
    providerId: "naver",
    emailAddress: `${id}@example.com`,
    authMode: "app-password",
    incomingProtocol: "imap",
    encryptedSecretRef: "secret",
    createdAt: now,
    updatedAt: now
  };
}

test("opens the message of the requested account when UIDs repeat", async () => {
  const accounts = new InMemoryAccountRepository();
  for (const id of ["account-a", "account-b"]) {
    await accounts.addAccount(account(id));
    await accounts.saveIncomingMessage({
      accountId: id,
      providerMessageId: "5",
      mailbox: "INBOX",
      from: `${id}@sender.example`,
      subject: `subject of ${id}`,
      receivedAt: new Date(id === "account-a" ? 2000 : 1000),
      hasAttachments: false
    });
  }
  const opened: string[] = [];
  const app = Fastify();
  await registerRoutes(app, {
    accounts,
    sender: {} as never,
    validateAccount: async () => undefined,
    fetchMessageContent: async (mailAccount) => {
      opened.push(mailAccount.id);
      return { text: "body", truncated: false, links: [] };
    },
    startAccountSync: async () => undefined,
    resumeAccountSync: async () => undefined,
    stopAccountSync: async () => undefined
  });

  const scoped = await app.inject({ method: "GET", url: "/accounts/account-b/messages/5" });
  assert.equal(scoped.statusCode, 200);
  assert.equal(scoped.json().subject, "subject of account-b");
  assert.deepEqual(opened, ["account-b"]);

  // The UID-only lookup that could pick another account's message is gone.
  const unscoped = await app.inject({ method: "GET", url: "/mail/messages/5" });
  assert.equal(unscoped.statusCode, 404);
});
