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

test("one fetch requests both header sets; references ignore List-* tokens", async () => {
  const { ImapReceiver } = await import("../src/mail/ImapReceiver.js");
  let requested: string[] = [];
  const client = {
    async *fetch(_uids: number[], query: { headers: string[] }) {
      requested = query.headers;
      yield {
        uid: 7,
        flags: new Set<string>(),
        envelope: { from: [{ address: "news@example.test" }], subject: "s", date: new Date(0) },
        headers: Buffer.from(
          "List-Unsubscribe: <mailto:u@example.test>\r\nList-Id: <list.example.test>\r\n" +
          "References: <a@example.test>\r\n <b@example.test>\r\n\r\n"
        )
      };
    }
  };
  const receiver = new ImapReceiver({} as never, {} as never) as unknown as {
    fetchUids: (c: unknown, a: unknown, m: string, u: number[]) => Promise<Array<{ category?: string; references?: string[] }>>;
  };
  const [summary] = await receiver.fetchUids(client, { id: "a" }, "INBOX", [7]);
  assert.ok(requested.includes("references") && requested.includes("list-unsubscribe"));
  assert.equal(summary?.category, "newsletter");
  assert.deepEqual(summary?.references, ["<a@example.test>", "<b@example.test>"]);
});
