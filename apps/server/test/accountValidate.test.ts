import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import type { MailAccount } from "../src/domain/types.js";
import { registerRoutes } from "../src/api/routes.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";

async function validate(syncErrorCode: MailAccount["syncErrorCode"]) {
  const now = new Date();
  const accounts = new InMemoryAccountRepository();
  await accounts.addAccount({
    id: "account-1",
    userId: "demo-user",
    providerId: "naver",
    emailAddress: "user@example.com",
    authMode: "app-password",
    incomingProtocol: "imap",
    encryptedSecretRef: "app-password",
    syncStatus: syncErrorCode ? "error" : "idle",
    syncErrorCode,
    createdAt: now,
    updatedAt: now
  });
  let starts = 0;
  const app = Fastify();
  await registerRoutes(app, {
    accounts,
    sender: {} as never,
    validateAccount: async () => undefined,
    fetchMessageContent: async () => {
      throw new Error("unused");
    },
    startAccountSync: async () => undefined,
    resumeAccountSync: async () => {
      starts += 1;
    },
    stopAccountSync: async () => undefined
  });

  const response = await app.inject({
    method: "POST",
    url: "/accounts/account-1/validate"
  });
  return { status: response.statusCode, starts };
}

test("resumes the watcher after a passing validation", async () => {
  assert.deepEqual(await validate("authentication"), { status: 200, starts: 1 });
  // An earlier failed check may have cleared the code; still resume.
  assert.deepEqual(await validate(undefined), { status: 200, starts: 1 });
});
