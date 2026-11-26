import assert from "node:assert/strict";
import test from "node:test";
import { replyFields } from "../src/mail/replyRecipients.js";
import { threadingHeaders } from "../src/mail/SmtpSender.js";

const account = { emailAddress: "Me@Example.com" };
const thread = (over = {}) => ({
  messageId: "<m1@x>",
  references: ["<r0@x>"],
  replyTo: [],
  to: ["me@example.com", "bob@example.com"],
  cc: ["carol@example.com", "ME@example.com", "bob@example.com"],
  ...over
});

test("reply uses From when no Reply-To", () => {
  const r = replyFields({ from: "alice@example.com" }, { thread: thread() }, account);
  assert.deepEqual(r.replyTo, ["alice@example.com"]);
  assert.equal(r.messageId, "<m1@x>");
});

test("reply prefers Reply-To", () => {
  const r = replyFields(
    { from: "alice@example.com" },
    { thread: thread({ replyTo: ["list@example.com"] }) },
    account
  );
  assert.deepEqual(r.replyTo, ["list@example.com"]);
});

test("reply-all drops own address and duplicates", () => {
  const r = replyFields({ from: "alice@example.com" }, { thread: thread() }, account);
  assert.deepEqual(r.replyAllTo, ["alice@example.com", "bob@example.com"]);
  assert.deepEqual(r.replyAllCc, ["carol@example.com"]);
});

test("missing thread headers still reply to sender", () => {
  const r = replyFields({ from: "a@x.com, b@x.com" }, {}, account);
  assert.deepEqual(r.replyTo, ["a@x.com", "b@x.com"]);
  assert.equal(r.messageId, undefined);
});

test("threadingHeaders appends parent id to References", () => {
  assert.deepEqual(
    threadingHeaders({ inReplyTo: "<m1@x>", references: ["<r0@x>"] }),
    { inReplyTo: "<m1@x>", references: ["<r0@x>", "<m1@x>"] }
  );
  assert.deepEqual(threadingHeaders({}), {});
});
