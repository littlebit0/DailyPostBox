import assert from "node:assert/strict";
import test from "node:test";
import { Readable } from "node:stream";
import Fastify from "fastify";
import nodemailer from "nodemailer";
import type { MailAccount, OutgoingMessageDraft } from "../src/domain/types.js";
import { registerRoutes } from "../src/api/routes.js";
import { SendQueue } from "../src/mail/SendQueue.js";
import { mailOptions } from "../src/mail/SmtpSender.js";
import { selectForwardedAttachments } from "../src/mail/forwarding.js";
import { InMemoryAccountRepository } from "../src/workers/AccountRepository.js";

const attachments = [
  { part: "2", filename: "a.pdf", contentType: "application/pdf", size: 3 },
  { part: "3", filename: "b.txt", contentType: "text/plain", size: 3 }
];

async function setup(options: { missingAtSend?: string } = {}) {
  const now = new Date();
  const accounts = new InMemoryAccountRepository();
  for (const id of ["a1", "a2"]) {
    await accounts.addAccount({
      id,
      userId: "demo-user",
      providerId: "naver",
      emailAddress: `${id}@example.test`,
      authMode: "app-password",
      incomingProtocol: "imap",
      encryptedSecretRef: "x",
      syncStatus: "idle",
      createdAt: now,
      updatedAt: now
    } as MailAccount);
  }
  await accounts.saveIncomingMessage({
    accountId: "a1",
    providerMessageId: "7",
    mailbox: "INBOX",
    from: "",
    subject: "",
    receivedAt: now,
    hasAttachments: true
  });
  const sent: OutgoingMessageDraft[] = [];
  const downloaded: string[] = [];
  const sender = {
    send: async (_a: MailAccount, draft: OutgoingMessageDraft) => {
      sent.push(draft);
      return { accepted: draft.to, rejected: [] };
    }
  };
  const sendQueue = new SendQueue(sender as never);
  const app = Fastify();
  await registerRoutes(app, {
    accounts,
    sender: sender as never,
    sendQueue,
    fetchMessageContent: async () => ({
      text: "body",
      attachments,
      thread: { references: [], replyTo: [], to: ["t@example.test"], cc: ["c@example.test"] }
    }),
    // Search-only message 9 is reachable through the IMAP fallback.
    fetchMessageSummary: async (_a: unknown, id: string) => id === "9"
      ? { accountId: "a1", providerMessageId: "9", mailbox: "INBOX", from: "", subject: "", receivedAt: now, hasAttachments: true }
      : null,
    downloadAttachment: async (_a: unknown, _m: unknown, part: string) => {
      if (part === options.missingAtSend) return null;
      downloaded.push(part);
      return {
        filename: attachments.find((a) => a.part === part)!.filename,
        contentType: "application/octet-stream",
        stream: Readable.from([Buffer.from(`p${part}`)]),
        close: async () => undefined
      };
    }
  } as never);
  const send = (forwardOf: unknown, extra: Record<string, unknown> = {}) =>
    app.inject({
      method: "POST",
      url: "/mail/send",
      remoteAddress: "127.0.0.1",
      payload: {
        accountId: "a1",
        to: ["x@example.test"],
        subject: "Fwd: hi",
        delaySeconds: 0,
        forwardOf,
        ...extra
      }
    });
  const settle = () => new Promise((r) => setTimeout(r, 30));
  return { app, sent, downloaded, send, settle };
}

test("forward attaches only the selected original parts through the queue", async () => {
  const { sent, downloaded, send, settle } = await setup();
  const res = await send({ messageId: "7", parts: ["3"] });
  assert.equal(res.statusCode, 202);
  await settle();
  assert.deepEqual(downloaded, ["3"]);
  assert.equal(sent.length, 1);
  assert.deepEqual(
    sent[0].forwardedAttachments?.map((a) => [a.filename, a.content.toString()]),
    [["b.txt", "p3"]]
  );
  assert.equal(sent[0].inReplyTo, undefined);
});

test("search-only messages forward through the IMAP fallback", async () => {
  const { sent, send, settle } = await setup();
  assert.equal((await send({ messageId: "9", parts: ["2"] })).statusCode, 202);
  await settle();
  assert.equal(sent[0].forwardedAttachments?.[0].filename, "a.pdf");
});

test("forwardOf is validated before queueing", async () => {
  const { app, sent, send, settle } = await setup();
  assert.equal((await send({ messageId: "7", parts: ["9"] })).statusCode, 400);
  assert.equal((await send({ messageId: "7", parts: ["2", "2"] })).statusCode, 400);
  assert.ok((await send({ messageId: "7", parts: ["../2"] })).statusCode >= 400);
  assert.equal((await send({ messageId: "8", parts: ["2"] })).statusCode, 404);
  // Message 7 belongs to a1, so a2 cannot forward it.
  assert.equal((await send({ messageId: "7", parts: ["2"] }, { accountId: "a2" })).statusCode, 404);
  const remote = await app.inject({
    method: "POST",
    url: "/mail/send",
    remoteAddress: "192.168.0.5",
    payload: { accountId: "a1", to: ["x@example.test"], forwardOf: { messageId: "7", parts: ["2"] } }
  });
  assert.equal(remote.statusCode, 403);
  await settle();
  assert.equal(sent.length, 0);
});

test("an attachment missing at send time fails the send instead of dropping it", async () => {
  const { app, sent, send, settle } = await setup({ missingAtSend: "2" });
  const { id } = (await send({ messageId: "7", parts: ["2", "3"] })).json();
  await settle();
  assert.equal(sent.length, 0);
  const status = (await app.inject({ url: `/mail/send/${id}` })).json();
  assert.equal(status.status, "failed");
  assert.deepEqual(status.draft.forwardOf.parts, ["2", "3"]);
  assert.deepEqual(status.draft.forwardOf.attachments.map((a: { filename: string }) => a.filename), ["a.pdf", "b.txt"]);
  assert.equal(status.draft.forwardedAttachments, undefined);
});

test("message detail exposes the original To/Cc for the forward header", async () => {
  const { app } = await setup();
  const detail = (await app.inject({ url: "/accounts/a1/messages/7", remoteAddress: "127.0.0.1" })).json();
  assert.deepEqual(detail.to, ["t@example.test"]);
  assert.deepEqual(detail.cc, ["c@example.test"]);
});

test("selectForwardedAttachments enforces the size cap", () => {
  assert.deepEqual(selectForwardedAttachments(attachments, ["2"], 10), { attachments: [attachments[0]] });
  assert.equal((selectForwardedAttachments(attachments, ["2", "3"], 5) as { status: number }).status, 413);
});

test("forwarded mail carries attachments and no In-Reply-To header", async () => {
  const transport = nodemailer.createTransport({ streamTransport: true, buffer: true } as never);
  const info = await transport.sendMail(mailOptions(
    { emailAddress: "a1@example.test" },
    {
      accountId: "a1",
      to: ["x@example.test"],
      subject: "Fwd: hi",
      text: "---------- Forwarded message ----------",
      forwardOf: { messageId: "7", parts: ["2"] },
      forwardedAttachments: [{ filename: "a.pdf", contentType: "application/pdf", content: Buffer.from("pdf") }]
    }
  )) as unknown as { message: Buffer };
  const raw = info.message.toString();
  assert.match(raw, /^Subject: Fwd: hi/m);
  assert.match(raw, /filename=a\.pdf/);
  assert.doesNotMatch(raw, /^In-Reply-To:/im);
  assert.doesNotMatch(raw, /^References:/im);
});
