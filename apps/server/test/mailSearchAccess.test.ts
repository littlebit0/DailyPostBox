import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import { registerRoutes } from "../src/api/routes.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";
import { SnoozeStore } from "../src/workers/SnoozeStore.js";
import type { IncomingMessageSummary, MailAccount } from "../src/domain/types.js";

const account = {
  id: "a1",
  userId: "demo-user",
  providerId: "custom",
  emailAddress: "me@example.test",
  authMode: "password",
  incomingProtocol: "imap",
  encryptedSecretRef: "x"
} as unknown as MailAccount;

const summary = {
  accountId: "a1",
  providerMessageId: "9",
  from: "sender@example.test",
  receivedAt: new Date(0)
} as unknown as IncomingMessageSummary;

async function build() {
  const accounts = new InMemoryAccountRepository();
  await accounts.addAccount(account);
  let fetched = 0;
  const app = Fastify();
  const snoozes = new SnoozeStore(undefined, () => undefined);
  await registerRoutes(app, {
    accounts,
    snoozes,
    searchMessages: async () => [summary],
    fetchMessageSummary: async () => { fetched++; return summary; },
    fetchMessageContent: async () => ({ text: "secret" })
  } as never);
  return { app, snoozes, fetched: () => fetched };
}

test("loopback may search and use the IMAP fallback", async () => {
  const { app } = await build();
  const search = await app.inject({ url: "/accounts/a1/search?q=hi", remoteAddress: "127.0.0.1" });
  assert.equal(search.statusCode, 200);
  const detail = await app.inject({ url: "/accounts/a1/messages/9", remoteAddress: "::1" });
  assert.equal(detail.statusCode, 200);
});

test("search results hide snoozed messages", async () => {
  const { app, snoozes } = await build();
  await snoozes.snooze("a1", "9", new Date(Date.now() + 60_000));
  try {
    const search = await app.inject({ url: "/accounts/a1/search?q=hi", remoteAddress: "127.0.0.1" });
    assert.equal(search.statusCode, 200);
    assert.deepEqual(search.json(), []);
  } finally {
    await snoozes.cancel("a1", "9");
  }
});

test("remote callers get 403 on search and 404 without IMAP fallback", async () => {
  const { app, fetched } = await build();
  const search = await app.inject({ url: "/accounts/a1/search?q=hi", remoteAddress: "192.168.0.5" });
  assert.equal(search.statusCode, 403);
  const detail = await app.inject({ url: "/accounts/a1/messages/9", remoteAddress: "192.168.0.5" });
  assert.equal(detail.statusCode, 404);
  assert.equal(fetched(), 0);
});

test("ALLOW_REMOTE_MAIL_SEARCH=true opts remote callers in", async () => {
  process.env.ALLOW_REMOTE_MAIL_SEARCH = "true";
  try {
    const { app } = await build();
    const res = await app.inject({ url: "/accounts/a1/search?q=hi", remoteAddress: "192.168.0.5" });
    assert.equal(res.statusCode, 200);
  } finally {
    delete process.env.ALLOW_REMOTE_MAIL_SEARCH;
  }
});

test("loopback peer with an Origin header is rejected (browser)", async () => {
  const { app } = await build();
  const res = await app.inject({
    url: "/accounts/a1/search?q=hi",
    remoteAddress: "127.0.0.1",
    headers: { origin: "https://evil.example" }
  });
  assert.equal(res.statusCode, 403);
});

test("loopback peer with a non-loopback Host is rejected (DNS rebinding)", async () => {
  const { app } = await build();
  const res = await app.inject({
    url: "/accounts/a1/search?q=hi",
    remoteAddress: "127.0.0.1",
    headers: { host: "evil.example:8080" }
  });
  assert.equal(res.statusCode, 403);
});

test("plain loopback with 127.0.0.1:port Host is allowed", async () => {
  const { app } = await build();
  const res = await app.inject({
    url: "/accounts/a1/search?q=hi",
    remoteAddress: "127.0.0.1",
    headers: { host: "127.0.0.1:8080" }
  });
  assert.equal(res.statusCode, 200);
});
