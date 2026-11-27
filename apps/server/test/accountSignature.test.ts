import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import type { MailAccount } from "../src/domain/types.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";

process.env.GOOGLE_OAUTH_CLIENT_ID = "test-client";
const { registerRoutes } = await import("../src/api/routes.js");

async function setup() {
  const now = new Date();
  const account: MailAccount = {
    id: "account-1",
    userId: "demo-user",
    providerId: "naver",
    emailAddress: "user@example.com",
    authMode: "app-password",
    incomingProtocol: "imap",
    encryptedSecretRef: "secret",
    createdAt: now,
    updatedAt: now
  };
  const accounts = new InMemoryAccountRepository();
  await accounts.addAccount(account);
  const app = Fastify();
  await registerRoutes(app, { accounts } as never);
  return { app, accounts };
}

test("saves, lists and clears an account signature", async () => {
  const { app, accounts } = await setup();

  const saved = await app.inject({
    method: "PUT",
    url: "/accounts/account-1/signature",
    payload: { signature: "  Kim\nExample Corp  " }
  });
  assert.equal(saved.statusCode, 200);
  assert.equal(saved.json().signature, "Kim\nExample Corp");
  assert.equal(saved.json().encryptedSecretRef, undefined);
  assert.equal((await accounts.getAccount("account-1"))?.signature, "Kim\nExample Corp");

  const listed = await app.inject({ method: "GET", url: "/accounts" });
  assert.equal(listed.json()[0].signature, "Kim\nExample Corp");

  await app.inject({
    method: "PUT",
    url: "/accounts/account-1/signature",
    payload: { signature: "   " }
  });
  assert.equal((await accounts.getAccount("account-1"))?.signature, undefined);
});

test("rejects unknown accounts", async () => {
  const { app } = await setup();
  const response = await app.inject({
    method: "PUT",
    url: "/accounts/missing/signature",
    payload: { signature: "x" }
  });
  assert.equal(response.statusCode, 404);
});
