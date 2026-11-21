import assert from "node:assert/strict";
import test from "node:test";
import type { IncomingMessageSummary } from "../src/domain/types.js";
import {
  MAX_REFERENCES,
  boundMessageId,
  computeThreadId,
  parseMessageIds,
  withThreadInfo
} from "../src/mail/threading.js";

function summary(
  id: string,
  extra: Partial<IncomingMessageSummary>
): IncomingMessageSummary {
  return {
    accountId: "a",
    providerMessageId: id,
    mailbox: "INBOX",
    from: "x@example.com",
    subject: "Hello",
    receivedAt: new Date(),
    hasAttachments: false,
    ...extra
  };
}

test("prefers the Gmail thread id", () => {
  assert.equal(
    computeThreadId({ gmailThreadId: "99", messageId: "<a@x>" }),
    "gm:99"
  );
});

test("uses the References root for replies and the message id for the root", () => {
  const root = computeThreadId({ messageId: "<a@x>" });
  const reply = computeThreadId({
    messageId: "<c@x>",
    inReplyTo: "<b@x>",
    references: ["<a@x>", "<b@x>"]
  });
  assert.equal(root, reply);
  assert.equal(computeThreadId({ inReplyTo: "<a@x>" }), root);
  assert.equal(computeThreadId({}), undefined);
});

test("does not group mail that only shares a subject", () => {
  const list = withThreadInfo([
    summary("1", { messageId: "<a@x>" }),
    summary("2", { messageId: "<b@x>" }),
    summary("3", { messageId: "<c@x>", references: ["<a@x>"] }),
    summary("4", {})
  ]);
  assert.deepEqual(list.map((item) => item.threadCount), [2, 1, 2, 1]);
  assert.equal(list[3].threadId, undefined);
});

test("parses message ids from a References header", () => {
  assert.deepEqual(parseMessageIds("<a@x>\r\n <b@x>"), ["<a@x>", "<b@x>"]);
  assert.deepEqual(parseMessageIds(undefined), []);
});

test("resolves In-Reply-To ancestry to a common root without References", () => {
  const list = withThreadInfo([
    summary("1", { messageId: "<a@x>" }),
    summary("2", { messageId: "<b@x>", inReplyTo: "<a@x>" }),
    summary("3", { messageId: "<c@x>", inReplyTo: "<b@x>" })
  ]);
  assert.deepEqual(list.map((item) => item.threadCount), [3, 3, 3]);
});

test("keeps the thread id short for very long message ids", () => {
  const id = computeThreadId({ messageId: `<${"a".repeat(300)}@x>` })!;
  assert.ok(id.length <= 100);
});

test("bounds a 4 MiB References header", () => {
  const huge = "<a>".repeat((4 * 1024 * 1024) / 3);
  const ids = parseMessageIds(huge);
  assert.ok(ids.length <= MAX_REFERENCES);
  assert.ok(JSON.stringify(ids).length < 4096);
});

test("keeps root and latest ids of a long chain, drops over-long ids", () => {
  const chain = Array.from({ length: 100 }, (_, i) => `<m${i}@x>`).join(" ");
  const ids = parseMessageIds(chain);
  assert.equal(ids.length, MAX_REFERENCES);
  assert.equal(ids[0], "<m0@x>");
  assert.equal(ids.at(-1), "<m99@x>");
  assert.deepEqual(parseMessageIds(`<${"a".repeat(2000)}> <ok@x>`), ["<ok@x>"]);
});

test("boundMessageId drops over-long values", () => {
  assert.equal(boundMessageId("<a@x>"), "<a@x>");
  assert.equal(boundMessageId(`<${"a".repeat(5000)}>`), undefined);
});

test("resolves a 10,000-message reply chain in linear time", () => {
  const n = 10_000;
  const messages = Array.from({ length: n }, (_, i) => ({
    accountId: "a",
    providerMessageId: String(i + 1),
    mailbox: "INBOX",
    from: "a@example.com",
    subject: "s",
    receivedAt: new Date(i * 1000),
    hasAttachments: false,
    messageId: `<m${i}@x>`,
    inReplyTo: i === 0 ? undefined : `<m${i - 1}@x>`
  }));
  // Worst case order: deepest message first, then the rest.
  messages.reverse();
  const started = Date.now();
  const out = withThreadInfo(messages);
  assert.ok(Date.now() - started < 1000);
  assert.equal(new Set(out.map((m) => m.threadId)).size, 1);
  assert.equal(out[0]!.threadCount, n);
});
