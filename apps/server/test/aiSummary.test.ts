import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import { createAiSummarizer } from "../src/ai/AiSummarizer.js";
import { registerRoutes } from "../src/api/routes.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";

function mockFetch(status = 200, body: unknown = { content: [{ type: "text", text: "요약 결과" }] }) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fn = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    return new Response(JSON.stringify(body), { status });
  }) as unknown as typeof fetch;
  return { fn, calls };
}

async function build(summarizer: ReturnType<typeof createAiSummarizer>) {
  const now = new Date();
  const accounts = new InMemoryAccountRepository();
  await accounts.addAccount({
    id: "a1", userId: "demo-user", providerId: "naver", emailAddress: "u@example.test",
    authMode: "app-password", incomingProtocol: "imap", encryptedSecretRef: "x",
    syncStatus: "idle", createdAt: now, updatedAt: now
  });
  await accounts.saveIncomingMessage({
    accountId: "a1", providerMessageId: "m1", mailbox: "INBOX", from: "s@example.test",
    subject: "제목", receivedAt: now, hasAttachments: false
  });
  const app = Fastify();
  await registerRoutes(app, {
    accounts, summarizer, sender: {} as never,
    validateAccount: async () => undefined,
    fetchMessageContent: async () => ({ text: "본문 내용", truncated: false, links: [] }),
    startAccountSync: async () => undefined,
    resumeAccountSync: async () => undefined,
    stopAccountSync: async () => undefined
  });
  return app;
}

test("disabled by default: features false, summary 404, no fetch", async () => {
  const { fn, calls } = mockFetch();
  const app = await build(createAiSummarizer({ enabled: false, apiKey: "k", model: "m" }, fn));
  assert.deepEqual((await app.inject("/features")).json(), { aiSummary: false });
  const res = await app.inject({ method: "POST", url: "/accounts/a1/messages/m1/summary" });
  assert.equal(res.statusCode, 404);
  assert.equal(calls.length, 0);
});

test("enabled without key stays disabled", async () => {
  const app = await build(createAiSummarizer({ enabled: true, model: "m" }, mockFetch().fn));
  assert.deepEqual((await app.inject("/features")).json(), { aiSummary: false });
});

test("enabled: calls Messages API and returns summary", async () => {
  const { fn, calls } = mockFetch();
  const app = await build(createAiSummarizer({ enabled: true, apiKey: "test-key", model: "test-model" }, fn));
  assert.deepEqual((await app.inject("/features")).json(), { aiSummary: true });
  const res = await app.inject({ method: "POST", url: "/accounts/a1/messages/m1/summary" });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.json(), { summary: "요약 결과" });
  assert.equal(calls[0].url, "https://api.anthropic.com/v1/messages");
  const headers = calls[0].init.headers as Record<string, string>;
  assert.equal(headers["x-api-key"], "test-key");
  assert.equal(headers["anthropic-version"], "2023-06-01");
  const sent = JSON.parse(calls[0].init.body as string);
  assert.equal(sent.model, "test-model");
  assert.match(sent.messages[0].content, /본문 내용/);
});

test("upstream failure returns 502 without leaking details", async () => {
  const app = await build(createAiSummarizer({ enabled: true, apiKey: "k", model: "m" }, mockFetch(500, {}).fn));
  const res = await app.inject({ method: "POST", url: "/accounts/a1/messages/m1/summary" });
  assert.equal(res.statusCode, 502);
  assert.doesNotMatch(res.body, /본문 내용/);
});
