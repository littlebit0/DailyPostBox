import assert from "node:assert/strict";
import test from "node:test";
import { parseListUnsubscribe, readHeader } from "../src/mail/listUnsubscribe.js";

test("returns undefined without a usable header", () => {
  assert.equal(parseListUnsubscribe(undefined), undefined);
  assert.equal(parseListUnsubscribe("garbage"), undefined);
  assert.equal(parseListUnsubscribe("<ftp://x.test/u>, <javascript:alert(1)>"), undefined);
});

test("parses url and mailto entries", () => {
  const parsed = parseListUnsubscribe(
    "<mailto:unsub@example.test?subject=Unsubscribe%20me>, <https://example.test/u?id=1>"
  );
  assert.deepEqual(parsed, {
    url: "https://example.test/u?id=1",
    mailto: { address: "unsub@example.test", subject: "Unsubscribe me", body: undefined },
    oneClick: false
  });
});

test("detects RFC 8058 one-click only with a url", () => {
  const post = "List-Unsubscribe=One-Click";
  assert.equal(parseListUnsubscribe("<https://example.test/u>", post)?.oneClick, true);
  assert.equal(parseListUnsubscribe("<mailto:a@example.test>", post)?.oneClick, false);
});

test("rejects malformed mailto addresses", () => {
  assert.equal(parseListUnsubscribe("<mailto:not-an-address>"), undefined);
});

test("reads folded headers", () => {
  const raw = "List-Unsubscribe: <mailto:a@example.test>,\r\n <https://example.test/u>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n\r\n";
  assert.equal(
    readHeader(raw, "list-unsubscribe"),
    "<mailto:a@example.test>, <https://example.test/u>"
  );
  assert.equal(readHeader(raw, "X-Missing"), undefined);
});

test("keeps literal plus signs in mailto subject and body", () => {
  const parsed = parseListUnsubscribe(
    "<mailto:leave@example.test?subject=a+b&body=user+tag@example.test%2Bx>"
  );
  assert.equal(parsed?.mailto?.subject, "a+b");
  assert.equal(parsed?.mailto?.body, "user+tag@example.test+x");
});
