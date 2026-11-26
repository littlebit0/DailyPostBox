import assert from "node:assert/strict";
import test from "node:test";
import Fastify from "fastify";
import type { MailAccount } from "../src/domain/types.js";
import { registerRoutes } from "../src/api/routes.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";

async function addCustom(connectionOverride?: unknown) {
  const validated: MailAccount[] = [];
  const app = Fastify();
  await registerRoutes(app, {
    accounts: new InMemoryAccountRepository(),
    sender: {} as never,
    validateAccount: async (account) => {
      validated.push(account);
    },
    fetchMessageContent: async () => {
      throw new Error("unused");
    },
    startAccountSync: async () => undefined,
    resumeAccountSync: async () => undefined,
    stopAccountSync: async () => undefined
  });
  const response = await app.inject({
    method: "POST",
    url: "/accounts",
    payload: {
      providerId: "custom",
      emailAddress: "me@example.com",
      authMode: "password",
      incomingProtocol: "imap",
      secret: "password",
      connectionOverride
    }
  });
  return { response, validated };
}

test("a custom account without server settings is rejected", async () => {
  const { response, validated } = await addCustom();
  // server.ts maps this ZodError to 400; the bare test app keeps the issue text.
  assert.notEqual(response.statusCode, 201);
  assert.match(response.body, /사용자 지정 메일 서버는/);
  assert.equal(validated.length, 0);
});

test("a custom account connects with its own servers", async () => {
  const connectionOverride = {
    incoming: { host: "imap.example.com", port: 993, secure: true },
    outgoing: { host: "smtp.example.com", port: 587, secure: false }
  };
  const { response, validated } = await addCustom(connectionOverride);
  assert.equal(response.statusCode, 201);
  assert.deepEqual(validated[0]?.connectionOverride, connectionOverride);
});
