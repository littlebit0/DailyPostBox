import assert from "node:assert/strict";
import test from "node:test";
import type { IncomingMessageSummary } from "../src/domain/types.js";
import { suggestContacts } from "../src/contacts/suggestContacts.js";

function message(from: string, day: number): IncomingMessageSummary {
  return {
    accountId: "a",
    providerMessageId: `${from}-${day}`,
    mailbox: "INBOX",
    from,
    subject: "",
    receivedAt: new Date(Date.UTC(2026, 10, day)),
    hasAttachments: false
  };
}

test("ranks by frequency then recency and matches substrings case-insensitively", () => {
  const result = suggestContacts(
    [
      message("Alice@example.test", 1),
      message("alice@example.test", 2),
      message("alan@example.test", 20),
      message("bob@example.test", 21),
      message("carol@example.test, ALAN@example.test", 22)
    ],
    "AL"
  );
  assert.deepEqual(
    result.map((item) => [item.address, item.count]),
    [["alan@example.test", 2], ["alice@example.test", 2]]
  );
  assert.equal(result[0].lastSeenAt, "2026-11-22T00:00:00.000Z");
});

test("empty query, empty from and limit", () => {
  assert.deepEqual(suggestContacts([message("a@example.test", 1)], " "), []);
  assert.deepEqual(suggestContacts([message("", 1)], "a"), []);
  const many = Array.from({ length: 5 }, (_, i) => message(`u${i}@example.test`, i + 1));
  assert.equal(suggestContacts(many, "u", 3).length, 3);
});

test("excludes non-repliable addresses but keeps normal ones", () => {
  const blocked = [
    "no_reply@email.apple.com", "noreply@x.test", "NoReply+tag@x.test", "no-reply@x.test",
    "do.not.reply@x.test", "donotreply@x.test", "do-not-reply@x.test", "notreply@x.test",
    "Mailer-Daemon@x.test", "postmaster@x.test", "bounce@x.test", "bounces+abc123@x.test"
  ];
  const result = suggestContacts(
    [...blocked.map((from, i) => message(from, i + 1)), message("ann@example.test", 1), message("replyguy@x.test", 2)],
    "@"
  );
  assert.deepEqual(result.map((item) => item.address).sort(), ["ann@example.test", "replyguy@x.test"]);
});
