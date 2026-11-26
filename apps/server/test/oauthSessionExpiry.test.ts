import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";

process.env.GOOGLE_OAUTH_CLIENT_ID = "test-client";
const { OAuthAccountFlow } = await import("../src/auth/OAuthAccountFlow.js");

function idToken(email: string): string {
  const payload = Buffer.from(JSON.stringify({ email })).toString("base64url");
  return `header.${payload}.signature`;
}

async function setup() {
  let now = Date.parse("2026-11-22T00:00:00Z");
  const accounts = new InMemoryAccountRepository();
  const flow = new OAuthAccountFlow({
    accounts,
    validateAccount: async () => undefined,
    startAccountSync: async () => undefined,
    stopAccountSync: async () => undefined,
    now: () => now
  });
  const app = Fastify();
  flow.register(app);
  const start = await app.inject({ method: "POST", url: "/auth/gmail/start", payload: {} });
  const { state, expiresAt } = start.json() as { state: string; expiresAt: string };
  return {
    app,
    flow,
    accounts,
    state,
    expiresAt,
    advance: (ms: number) => {
      now += ms;
    }
  };
}

async function withTokenEndpoint<T>(run: () => Promise<T>): Promise<T> {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () => new Response(JSON.stringify({
    access_token: "access",
    refresh_token: "refresh",
    expires_in: 3600,
    id_token: idToken("user@gmail.com")
  }), { status: 200 })) as typeof fetch;
  try {
    return await run();
  } finally {
    globalThis.fetch = originalFetch;
  }
}

test("an expired login session is rejected and removed", async () => {
  const { app, state, expiresAt, advance } = await setup();
  assert.equal(expiresAt, "2026-11-22T00:10:00.000Z");

  advance(10 * 60_000);
  const callback = await withTokenEndpoint(() =>
    app.inject({ method: "GET", url: `/auth/gmail/callback?code=code&state=${state}` })
  );
  assert.match(callback.body, /로그인 세션을 찾을 수 없습니다/);

  const status = await app.inject({ method: "GET", url: `/auth/sessions/${state}` });
  assert.equal(status.statusCode, 404);
});

test("a completed login keeps no tokens in the session", async () => {
  const { app, flow, accounts, state } = await setup();

  await withTokenEndpoint(() =>
    app.inject({ method: "GET", url: `/auth/gmail/callback?code=code&state=${state}` })
  );
  const complete = await app.inject({
    method: "POST",
    url: `/auth/sessions/${state}/complete`,
    payload: {}
  });

  assert.equal(complete.statusCode, 200);
  assert.equal((await accounts.listActiveAccounts()).length, 1);
  const sessions = (flow as unknown as { sessions: Map<string, { token?: unknown }> }).sessions;
  assert.equal(sessions.get(state)?.token, undefined);

  // Repeating the completion still answers with the created account.
  const again = await app.inject({
    method: "POST",
    url: `/auth/sessions/${state}/complete`,
    payload: {}
  });
  assert.equal(again.statusCode, 200);
});
