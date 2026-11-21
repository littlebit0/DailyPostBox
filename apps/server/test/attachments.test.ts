import assert from "node:assert/strict";
import test from "node:test";
import { extractAttachments } from "../src/mail/attachments.js";

test("extracts attachment parts and skips body parts", () => {
  const result = extractAttachments({
    type: "multipart/mixed",
    childNodes: [
      {
        part: "1",
        type: "multipart/alternative",
        childNodes: [
          { part: "1.1", type: "text/plain" },
          { part: "1.2", type: "text/html" }
        ]
      },
      {
        part: "2",
        type: "application/pdf",
        size: 1234,
        disposition: "attachment",
        dispositionParameters: { filename: "보고서.pdf" }
      },
      {
        part: "3",
        type: "IMAGE/PNG",
        size: 10,
        parameters: { name: "inline.png" }
      },
      { part: "4", type: "application/zip", disposition: "attachment" }
    ]
  });

  assert.deepEqual(result, [
    { part: "2", filename: "보고서.pdf", contentType: "application/pdf", size: 1234 },
    { part: "3", filename: "inline.png", contentType: "image/png", size: 10 },
    { part: "4", filename: "attachment-4", contentType: "application/zip", size: 0 }
  ]);
});

test("exposes an attached message itself instead of its inner parts", () => {
  const result = extractAttachments({
    type: "multipart/mixed",
    childNodes: [
      { part: "1", type: "text/plain" },
      {
        part: "2",
        type: "message/rfc822",
        size: 500,
        disposition: "attachment",
        dispositionParameters: { filename: "forwarded.eml" },
        childNodes: [
          { part: "2.1", type: "application/pdf", disposition: "attachment" }
        ]
      }
    ]
  });
  assert.deepEqual(result, [
    { part: "2", filename: "forwarded.eml", contentType: "message/rfc822", size: 500 }
  ]);
});

test("attachment route streams the part with an encoded filename", async () => {
  const { default: Fastify } = await import("fastify");
  const { Readable } = await import("node:stream");
  const { registerRoutes } = await import("../src/api/routes.js");
  const { InMemoryAccountRepository } = await import(
    "../src/workers/AccountRepository.js"
  );
  const now = new Date();
  const accounts = new InMemoryAccountRepository();
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
  });
  await accounts.saveIncomingMessage(
    {
      accountId: "a1",
      providerMessageId: "7",
      mailbox: "INBOX",
      from: "",
      subject: "",
      receivedAt: now,
      hasAttachments: true
    }
  );
  let closed = false;
  const app = Fastify();
  await registerRoutes(app, {
    accounts,
    sender: {} as never,
    validateAccount: async () => undefined,
    fetchMessageContent: async () => {
      throw new Error("unused");
    },
    downloadAttachment: async (_account, _message, part) =>
      part === "2"
        ? {
            filename: "보고서.pdf",
            contentType: "application/pdf",
            stream: Readable.from([Buffer.from("abc")]),
            close: async () => {
              closed = true;
            }
          }
        : null,
    startAccountSync: async () => undefined,
    resumeAccountSync: async () => undefined,
    stopAccountSync: async () => undefined
  });

  const ok = await app.inject("/accounts/a1/messages/7/attachments/2");
  assert.equal(ok.statusCode, 200);
  assert.equal(ok.body, "abc");
  assert.match(
    String(ok.headers["content-disposition"]),
    /filename\*=UTF-8''%EB%B3%B4%EA%B3%A0%EC%84%9C\.pdf/
  );
  assert.equal(closed, true);
  assert.equal(
    (await app.inject("/accounts/a1/messages/7/attachments/9")).statusCode,
    404
  );
  assert.equal(
    (await app.inject("/accounts/a1/messages/7/attachments/..%2Fx")).statusCode,
    500
  );
});
