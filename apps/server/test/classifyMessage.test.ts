import assert from "node:assert/strict";
import test from "node:test";
import { classifyMessage, parseRawHeaders } from "../src/mail/classifyMessage.js";

test("parses folded headers case-insensitively", () => {
  const h = parseRawHeaders("List-ID: <a.example.test>\r\nPrecedence:\r\n bulk\r\n\r\n");
  assert.equal(h["list-id"], "<a.example.test>");
  assert.equal(h["precedence"], "bulk");
});

test("newsletter by List-Unsubscribe, List-Id or bulk precedence", () => {
  assert.equal(classifyMessage({ "list-unsubscribe": "<mailto:u@example.test>" }, "news@example.test"), "newsletter");
  assert.equal(classifyMessage({ "list-id": "<x>" }, "a@example.test"), "newsletter");
  assert.equal(classifyMessage({ precedence: "Bulk" }, "a@example.test"), "newsletter");
});

test("notification by Auto-Submitted or automated sender", () => {
  assert.equal(classifyMessage({ "auto-submitted": "auto-generated" }, "a@example.test"), "notification");
  assert.equal(classifyMessage({ "auto-submitted": "no" }, "a@example.test"), "person");
  assert.equal(classifyMessage({}, "noreply@example.test"), "notification");
  assert.equal(classifyMessage({}, "no-reply+x@example.test"), "notification");
});

test("person otherwise", () => {
  assert.equal(classifyMessage({}, "alice@example.test"), "person");
  assert.equal(classifyMessage({}, ""), "person");
});
