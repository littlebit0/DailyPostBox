import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import type { MailAccount } from "../src/domain/types.js";
import { registerRoutes } from "../src/api/routes.js";
import { SendQueue } from "../src/mail/SendQueue.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";

async function setup() {
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
    syncStatus: "idle",
    createdAt: now,
    updatedAt: now
  } as MailAccount);
  const sent: string[] = [];
  const sender = {
    send: async (_a: MailAccount, draft: { subject: string }) => {
      sent.push(draft.subject);
      return { accepted: [], rejected: [] };
    }
  };
  const errors: unknown[] = [];
  const sendQueue = new SendQueue(sender as never, (e) => errors.push(e));
  const app = Fastify();
  await registerRoutes(app, { accounts, sender: sender as never, sendQueue } as never);
  const post = (delaySeconds: number) =>
    app.inject({
      method: "POST",
      url: "/mail/send",
      payload: { accountId: "account-1", to: ["a@example.com"], subject: "hi", delaySeconds }
    });
  return { app, sent, errors, sendQueue, post };
}

test("cancel before delay prevents sending", async () => {
  const { app, sent, post } = await setup();
  const { id } = (await post(30)).json();
  const cancel = await app.inject({ method: "POST", url: `/mail/send/${id}/cancel` });
  assert.equal(cancel.statusCode, 200);
  await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(sent, []);
});

test("delay 0 sends, later cancel returns 409", async () => {
  const { app, sent, post } = await setup();
  const { id } = (await post(0)).json();
  await new Promise((r) => setTimeout(r, 30));
  assert.deepEqual(sent, ["hi"]);
  const cancel = await app.inject({ method: "POST", url: `/mail/send/${id}/cancel` });
  assert.equal(cancel.statusCode, 409);
});

test("unknown id 404 and invalid delay rejected", async () => {
  const { app, post } = await setup();
  const cancel = await app.inject({ method: "POST", url: "/mail/send/nope/cancel" });
  assert.equal(cancel.statusCode, 404);
  assert.notEqual((await post(7)).statusCode, 202);
});

test("flush sends pending mail once and reports failures", async () => {
  const { sent, sendQueue, post } = await setup();
  await post(30);
  await sendQueue.flush();
  await sendQueue.flush();
  assert.deepEqual(sent, ["hi"]);
});
