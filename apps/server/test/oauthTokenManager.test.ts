import assert from "node:assert/strict";
import test from "node:test";
import type { MailAccount } from "../src/domain/types.js";
import { DevelopmentSecretResolver } from "../src/security/SecretResolver.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";

process.env.GOOGLE_OAUTH_CLIENT_ID = "test-client";
const { OAuthTokenManager } = await import("../src/auth/OAuthTokenManager.js");

function secret(accessToken: string, refreshToken: string, expiresAt: Date) {
  return JSON.stringify({
    type: "oauth2",
    accessToken,
    refreshToken,
    expiresAt: expiresAt.toISOString()
  });
}

async function refreshWhile(replaceDuringRefresh: boolean) {
  const now = new Date();
  const account: MailAccount = {
    id: "gmail-account",
    userId: "demo-user",
    providerId: "gmail",
    emailAddress: "user@gmail.com",
    authMode: "oauth2",
    incomingProtocol: "imap",
    encryptedSecretRef: secret("old-access", "old-refresh", new Date(0)),
    createdAt: now,
    updatedAt: now
  };
  const accounts = new InMemoryAccountRepository();
  await accounts.addAccount(account);
  const reconnected = secret(
    "new-access",
    "new-refresh",
    new Date(Date.now() + 3_600_000)
  );
  const manager = new OAuthTokenManager(new DevelopmentSecretResolver(), accounts);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () => {
    if (replaceDuringRefresh) account.encryptedSecretRef = reconnected;
    return new Response(JSON.stringify({
      access_token: "refreshed-old-grant",
      expires_in: 3600
    }), { status: 200 });
  }) as typeof fetch;

  try {
    const token = await manager.accessTokenFor(account);
    const stored = await accounts.getAccount(account.id);
    return { token, accessToken: JSON.parse(stored!.encryptedSecretRef).accessToken };
  } finally {
    globalThis.fetch = originalFetch;
  }
}

test("a refresh that finishes after reconnect keeps the new credentials", async () => {
  const result = await refreshWhile(true);
  assert.equal(result.token, "refreshed-old-grant");
  assert.equal(result.accessToken, "new-access");
});

test("a normal refresh persists the refreshed token", async () => {
  const result = await refreshWhile(false);
  assert.equal(result.accessToken, "refreshed-old-grant");
});
