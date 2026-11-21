import assert from "node:assert/strict";
import test from "node:test";
import type { IncomingMessageSummary } from "../src/domain/types.js";
import {
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
