import assert from "node:assert/strict";
import test from "node:test";
import { Readable } from "node:stream";
import { ImapReceiver } from "../src/mail/ImapReceiver.js";

const structure = {
  type: "multipart/alternative",
  childNodes: [
    { type: "text/plain", part: "1" },
    { type: "text/html", part: "2" }
  ]
};

async function fetchWith(htmlSize: number) {
  const receiver = new ImapReceiver({} as never, {} as never);
  const client = {
    connect: async () => undefined,
    mailboxOpen: async () => undefined,
    fetchOne: async () => ({ bodyStructure: structure }),
    download: async (_id: string, part: string) => ({
      content: Readable.from([
        part === "2" ? Buffer.alloc(htmlSize, "a") : Buffer.from("plain body")
      ])
    }),
    logout: async () => undefined
  };
  (receiver as unknown as { createClient: () => Promise<unknown> }).createClient = async () => client;
  return receiver.fetchMessageContent({} as never, "INBOX", "1");
}

test("truncated HTML part is not returned so plain text is used", async () => {
  const r = await fetchWith(2 * 1024 * 1024);
  assert.equal(r.text, "plain body");
  assert.ok(!r.html);
});

test("complete HTML part is still returned", async () => {
  const r = await fetchWith(100);
  assert.equal(r.text, "plain body");
  assert.equal(r.html, "a".repeat(100));
});
