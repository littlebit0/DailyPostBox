import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";

process.env.GOOGLE_OAUTH_CLIENT_ID = "test-client";
const { registerRoutes } = await import("../src/api/routes.js");

async function setup() {
  const accounts = new InMemoryAccountRepository();
  const now = new Date();
  await accounts.addAccount({
    id: "a1",
    userId: "demo-user",
    providerId: "naver",
    emailAddress: "u@example.com",
    authMode: "app-password",
    incomingProtocol: "imap",
    encryptedSecretRef: "x",
    syncStatus: "idle",
    createdAt: now,
    updatedAt: now
  } as never);
  await accounts.saveIncomingMessage({
    accountId: "a1",
    providerMessageId: "m1",
    mailbox: "INBOX",
    from: "s@example.com",
    subject: "s",
    receivedAt: now,
    hasAttachments: false
  });
  const app = Fastify();
  await registerRoutes(app, {
    accounts,
    sender: {} as never,
    fetchMessageContent: async () => ({
      text: "plain",
      truncated: false,
      links: [],
      html: '<p onclick="x()">Hi</p><script>alert(1)</script><img src="https://t.example/p.gif">'
    })
  } as never);
  return app;
}

test("message API blocks remote images unless remoteImages=allow", async () => {
  const app = await setup();
  const blocked = (await app.inject({ url: "/accounts/a1/messages/m1" })).json();
  assert.equal(blocked.html, "<p>Hi</p>");
  assert.equal(blocked.remoteImageCount, 1);
  assert.doesNotMatch(JSON.stringify(blocked), /t\.example/);

  const allowed = (
    await app.inject({ url: "/accounts/a1/messages/m1?remoteImages=allow" })
  ).json();
  assert.match(allowed.html, /https:\/\/t\.example\/p\.gif/);
  assert.doesNotMatch(allowed.html, /script|onclick/);
});
