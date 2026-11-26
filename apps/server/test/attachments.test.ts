import assert from "node:assert/strict";
import test from "node:test";
import {
  decodeTransferEncoding,
  estimateDecodedSize,
  extractAttachments,
  rawAttachmentFetch
} from "../src/mail/attachments.js";
import { ImapReceiver } from "../src/mail/ImapReceiver.js";

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

test("estimates decoded size for base64 parts only", () => {
  // Real file was 3,655 bytes; IMAP reported 5,012 encoded bytes.
  const decoded = estimateDecodedSize(5012, "base64");
  assert.equal(decoded, 3663);
  assert.ok(Math.abs(decoded - 3655) / 3655 < 0.01);
  assert.equal(estimateDecodedSize(5012, "quoted-printable"), 5012);
  assert.equal(estimateDecodedSize(5012), 5012);

  const [att] = extractAttachments({
    type: "multipart/mixed",
    childNodes: [
      { part: "1", type: "image/png", size: 5012, encoding: "BASE64", disposition: "attachment" }
    ]
  });
  assert.equal(att.size, 3663);
});

test("exposes a single-part message whose whole body is an attachment as part 1", () => {
  const root = {
    type: "application/pdf",
    size: 100,
    disposition: "attachment",
    dispositionParameters: { filename: "scan.pdf" }
  };
  assert.deepEqual(extractAttachments(root), [
    { part: "1", filename: "scan.pdf", contentType: "application/pdf", size: 100 }
  ]);
  assert.deepEqual(extractAttachments({ type: "text/plain" }), []);
});

test("picks a raw fetch for text attachments ImapFlow would convert", () => {
  const multipart = {
    type: "multipart/mixed",
    childNodes: [
      { part: "1", type: "text/plain" },
      { part: "2", type: "TEXT/PLAIN", encoding: "QUOTED-PRINTABLE", parameters: { name: "a.txt" } },
      { part: "3", type: "application/pdf", disposition: "attachment" }
    ]
  };
  assert.deepEqual(rawAttachmentFetch(multipart, "2"), { key: "2", encoding: "quoted-printable" });
  assert.equal(rawAttachmentFetch(multipart, "3"), null);
  assert.deepEqual(
    rawAttachmentFetch({ type: "text/html", encoding: "base64", parameters: { name: "p.html" } }, "1"),
    { key: "text", encoding: "base64" }
  );
});

test("decodes only the transfer encoding and keeps charset bytes", () => {
  // EUC-KR "가" is B0 A1; it must not be converted to UTF-8.
  assert.deepEqual(decodeTransferEncoding(Buffer.from("=B0=A1 =\r\nx"), "quoted-printable"), Buffer.from([0xb0, 0xa1, 0x20, 0x78]));
  assert.deepEqual(decodeTransferEncoding(Buffer.from("sKE=\r\n"), "base64"), Buffer.from([0xb0, 0xa1]));
  const flowed = Buffer.from("line \r\nwrap");
  assert.deepEqual(decodeTransferEncoding(flowed, "7bit"), flowed);
});

test("downloadAttachment returns original bytes for named inline text parts", async () => {
  const bodyStructure = {
    type: "multipart/mixed",
    childNodes: [
      { part: "1", type: "text/plain" },
      {
        part: "2",
        type: "text/plain",
        encoding: "quoted-printable",
        parameters: { name: "memo.txt", charset: "euc-kr", format: "flowed" }
      }
    ]
  };
  const calls: string[] = [];
  const client = {
    connect: async () => undefined,
    logout: async () => undefined,
    mailboxOpen: async () => undefined,
    fetchOne: async (_uid: string, query: { bodyParts?: string[] }) =>
      query.bodyParts
        ? { bodyParts: new Map([[query.bodyParts[0], Buffer.from("=B0=A1 =\r\nx")]]) }
        : { bodyStructure },
    download: async () => {
      calls.push("download");
      return { content: null };
    }
  };
  const receiver = Object.assign(new ImapReceiver({} as never, {} as never), {
    createClient: async () => client
  });
  const result = await receiver.downloadAttachment({} as never, "INBOX", "7", "2");
  assert.ok(result);
  const chunks: Buffer[] = [];
  for await (const chunk of result.stream) chunks.push(chunk as Buffer);
  assert.deepEqual(Buffer.concat(chunks), Buffer.from([0xb0, 0xa1, 0x20, 0x78]));
  assert.deepEqual(calls, []);
  await result.close();
});
