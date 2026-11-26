import assert from "node:assert/strict";
import test from "node:test";
import {
  SearchQueryError,
  parseSearchQuery,
  toImapSearch
} from "../src/mail/searchQuery.js";

test("plain text searches subject or sender", () => {
  assert.deepEqual(toImapSearch(parseSearchQuery("invoice march")), {
    or: [{ subject: "invoice march" }, { from: "invoice march" }]
  });
});

test("parses operators with quotes and combines them", () => {
  const search = toImapSearch(
    parseSearchQuery('from:alice@example.com subject:"주간 보고" after:2026-01-02 before:2026-02-01')
  );
  assert.equal(search.from, "alice@example.com");
  assert.equal(search.subject, "주간 보고");
  assert.equal((search.since as Date).toISOString(), "2026-01-02T00:00:00.000Z");
  assert.equal((search.before as Date).toISOString(), "2026-02-01T00:00:00.000Z");
  assert.equal(search.or, undefined);
});

test("keeps unknown operators as text and mixes them with operators", () => {
  assert.deepEqual(parseSearchQuery("from:bob 10:30 lunch"), {
    from: "bob",
    text: "10:30 lunch"
  });
});

test("rejects empty queries and invalid dates", () => {
  assert.throws(() => parseSearchQuery("   "), SearchQueryError);
  assert.throws(() => parseSearchQuery("before:2026-02-31"), SearchQueryError);
  assert.throws(() => parseSearchQuery("after:yesterday"), SearchQueryError);
});
