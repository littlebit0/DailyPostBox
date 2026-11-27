import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Fastify from "fastify";
import type { IncomingMessageSummary, MailAccount } from "../src/domain/types.js";
import { registerRoutes } from "../src/api/routes.js";
import { OAuthTokenRevoker } from "../src/auth/OAuthTokenRevoker.js";
import { DevelopmentSecretResolver } from "../src/security/SecretResolver.js";
import { LocalFileAccountRepository } from "../src/workers/LocalFileAccountRepository.js";
import { SnoozeStore } from "../src/workers/SnoozeStore.js";

const oauthSecret = JSON.stringify({
  type: "oauth2",
  accessToken: "access-secret",
  refreshToken: "refresh-secret"
});

function account(id: string, overrides: Partial<MailAccount> = {}): MailAccount {
  const now = new Date();
  return {
    id,
    userId: "demo-user",
    providerId: "gmail",
    emailAddress: `${id}@example.test`,
    authMode: "oauth2",
    incomingProtocol: "imap",
    encryptedSecretRef: oauthSecret,
    createdAt: now,
    updatedAt: now,
    ...overrides
  };
}

function message(accountId: string): IncomingMessageSummary {
  return {
    accountId,
    providerMessageId: "m1",
    mailbox: "INBOX",
    subject: "s",
    from: "a@example.test",
    receivedAt: new Date()
  } as IncomingMessageSummary;
}

function mockFetch(status: number | Error) {
  const calls: { url: string; body: string }[] = [];
  const fn = (async (url: string, init: { body: URLSearchParams }) => {
    calls.push({ url, body: init.body.toString() });
    if (status instanceof Error) throw status;
    return new Response("{}", { status });
  }) as unknown as typeof fetch;
  return { fn, calls };
}

test("revoker posts the refresh token to Google and never hits the network otherwise", async () => {
  const ok = mockFetch(200);
  const revoker = new OAuthTokenRevoker(new DevelopmentSecretResolver(), ok.fn);
  assert.equal(await revoker.revoke(account("a")), "revoked");
  assert.deepEqual(ok.calls, [
    { url: "https://oauth2.googleapis.com/revoke", body: "token=refresh-secret" }
  ]);

  const none = mockFetch(200);
  const other = new OAuthTokenRevoker(new DevelopmentSecretResolver(), none.fn);
  assert.equal(await other.revoke(account("b", { authMode: "app-password" })), "skipped");
  assert.equal(await other.revoke(account("c", { providerId: "outlook" })), "unsupported");
  assert.equal(none.calls.length, 0);
});

test("revoker reports failures without throwing", async () => {
  const secrets = new DevelopmentSecretResolver();
  assert.equal(await new OAuthTokenRevoker(secrets, mockFetch(500).fn).revoke(account("a")), "failed");
  assert.equal(
    await new OAuthTokenRevoker(secrets, mockFetch(new Error("net")).fn).revoke(account("a")),
    "failed"
  );
  assert.equal(await new OAuthTokenRevoker(secrets, mockFetch(400).fn).revoke(account("a")), "revoked");
});

test("revoker gives up on a stalled request and reports failed", async () => {
  const stalled = ((_url: string, init: { signal: AbortSignal }) =>
    new Promise((_resolve, reject) => {
      init.signal.addEventListener("abort", () => reject(init.signal.reason));
    })) as unknown as typeof fetch;
  const revoker = new OAuthTokenRevoker(new DevelopmentSecretResolver(), stalled, 20);
  assert.equal(await revoker.revoke(account("a")), "failed");
});

test("DELETE removes only that account's credentials and messages, even if revoke fails", async () => {
  const dir = await mkdtemp(join(tmpdir(), "dpb-delete-"));
  const file = join(dir, "state.json");
  const accounts = new LocalFileAccountRepository(file);
  await accounts.addAccount(account("a"));
  await accounts.addAccount(account("b"));
  await accounts.saveIncomingMessage(message("a"));
  await accounts.saveIncomingMessage(message("b"));

  const snoozes = new SnoozeStore(undefined, () => undefined);
  await snoozes.snooze("a", "1", new Date(Date.now() + 60_000));
  await snoozes.snooze("b", "1", new Date(Date.now() + 60_000));

  const revoker = new OAuthTokenRevoker(new DevelopmentSecretResolver(), mockFetch(500).fn);
  const app = Fastify();
  await registerRoutes(app, {
    accounts,
    snoozes,
    sender: {} as never,
    validateAccount: async () => undefined,
    fetchMessageContent: async () => {
      throw new Error("unused");
    },
    startAccountSync: async () => undefined,
    resumeAccountSync: async () => undefined,
    stopAccountSync: async () => undefined,
    revokeOAuthTokens: (a) => revoker.revoke(a)
  });

  const response = await app.inject({ method: "DELETE", url: "/accounts/a" });
  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.json(), { revoke: "failed" });

  const persisted = await readFile(file, "utf8");
  const state = JSON.parse(persisted) as { accounts: MailAccount[]; messages: { accountId: string }[] };
  assert.deepEqual(state.accounts.map((item) => item.id), ["b"]);
  assert.deepEqual(state.messages.map((item) => item.accountId), ["b"]);
  assert.deepEqual(snoozes.list().map((item) => item.accountId), ["b"]);
  snoozes.stop();
});
