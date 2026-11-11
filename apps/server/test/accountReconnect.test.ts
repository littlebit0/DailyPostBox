import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import type { MailAccount } from "../src/domain/types.js";
import { authenticationFailure } from "../src/mail/authenticationFailure.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";

process.env.GOOGLE_OAUTH_CLIENT_ID = "test-client";
const { registerRoutes } = await import("../src/api/routes.js");
const { OAuthAccountFlow } = await import("../src/auth/OAuthAccountFlow.js");

const goodSecret = "new-app-password";

function storedAccount(overrides: Partial<MailAccount> = {}): MailAccount {
  const now = new Date();
  return {
    id: "account-1",
    userId: "demo-user",
    providerId: "naver",
    emailAddress: "user@example.com",
    authMode: "app-password",
    incomingProtocol: "imap",
    encryptedSecretRef: "old-app-password",
    syncStatus: "error",
    syncError: "Command failed",
    syncErrorCode: "authentication",
    createdAt: now,
    updatedAt: now,
    ...overrides
  };
}

async function setup(account: MailAccount) {
  const accounts = new InMemoryAccountRepository();
  await accounts.addAccount(account);
  const calls: string[] = [];
  const deps = {
    accounts,
    validateAccount: async (candidate: MailAccount) => {
      const secret = candidate.encryptedSecretRef;
      if (secret !== goodSecret && !secret.includes("new-access")) {
        throw authenticationFailure("Authentication failed.");
      }
    },
    startAccountSync: async () => {
      calls.push("start");
    },
    stopAccountSync: async () => {
      calls.push("stop");
    }
  };
  const app = Fastify();
  await registerRoutes(app, {
    ...deps,
    sender: {} as never,
    fetchMessageContent: async () => {
      throw new Error("unused");
    }
  });
  new OAuthAccountFlow(deps).register(app);
  return { app, accounts, calls };
}

test("keeps the old app password when the new one fails", async () => {
  const { app, accounts, calls } = await setup(storedAccount());

  const response = await app.inject({
    method: "PUT",
    url: "/accounts/account-1/credentials",
    payload: { secret: "wrong" }
  });

  assert.equal(response.statusCode, 400);
  const account = await accounts.getAccount("account-1");
  assert.equal(account?.encryptedSecretRef, "old-app-password");
  assert.deepEqual(calls, []);
});

test("replaces the app password and restarts sync", async () => {
  const { app, accounts, calls } = await setup(storedAccount());

  const response = await app.inject({
    method: "PUT",
    url: "/accounts/account-1/credentials",
    payload: { secret: goodSecret }
  });

  assert.equal(response.statusCode, 200);
  assert.equal(response.json().encryptedSecretRef, undefined);
  const account = await accounts.getAccount("account-1");
  assert.equal(account?.encryptedSecretRef, goodSecret);
  assert.equal(account?.syncStatus, "syncing");
  assert.equal(account?.syncErrorCode, undefined);
  assert.deepEqual(calls, ["stop", "start"]);
});

function idToken(email: string): string {
  const payload = Buffer.from(JSON.stringify({ email })).toString("base64url");
  return `header.${payload}.signature`;
}

async function oauthReconnect(signedInEmail: string) {
  const gmail = storedAccount({
    providerId: "gmail",
    emailAddress: "user@gmail.com",
    authMode: "oauth2",
    encryptedSecretRef: JSON.stringify({
      type: "oauth2",
      accessToken: "old-access",
      refreshToken: "old-refresh"
    })
  });
  const { app, accounts, calls } = await setup(gmail);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () => new Response(JSON.stringify({
    access_token: "new-access",
    expires_in: 3600,
    id_token: idToken(signedInEmail)
  }), { status: 200 })) as typeof fetch;

  try {
    const start = await app.inject({
      method: "POST",
      url: "/auth/gmail/start",
      payload: { accountId: "account-1" }
    });
    const { state } = start.json() as { state: string };
    await app.inject({
      method: "GET",
      url: `/auth/gmail/callback?code=code&state=${state}`
    });
    const complete = await app.inject({
      method: "POST",
      url: `/auth/sessions/${state}/complete`,
      payload: {}
    });
    return {
      complete,
      account: await accounts.getAccount("account-1"),
      accountCount: (await accounts.listActiveAccounts()).length,
      calls
    };
  } finally {
    globalThis.fetch = originalFetch;
  }
}

test("browser sign-in replaces tokens on the same account", async () => {
  const result = await oauthReconnect("user@gmail.com");

  assert.equal(result.complete.statusCode, 200);
  assert.equal(result.accountCount, 1);
  const secret = JSON.parse(result.account!.encryptedSecretRef);
  assert.equal(secret.accessToken, "new-access");
  // Google may omit a new refresh token; the previous one is kept.
  assert.equal(secret.refreshToken, "old-refresh");
  assert.equal(result.account?.syncErrorCode, undefined);
  assert.deepEqual(result.calls, ["stop", "start"]);
});

test("browser sign-in with a different address leaves the account unchanged", async () => {
  const result = await oauthReconnect("other@gmail.com");

  assert.equal(result.complete.statusCode, 400);
  const secret = JSON.parse(result.account!.encryptedSecretRef);
  assert.equal(secret.accessToken, "old-access");
  assert.deepEqual(result.calls, []);
});
