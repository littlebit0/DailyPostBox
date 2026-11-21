import assert from "node:assert/strict";
import test from "node:test";
import { detectImapCapabilities } from "../src/mail/imapCapabilities.js";

test("detects IMAP capabilities from the CAPABILITY set", () => {
  const now = new Date("2026-11-22T00:00:00.000Z");
  const result = detectImapCapabilities(
    new Map<string, unknown>([["IMAP4REV1", true], ["IDLE", true], ["MOVE", true]]),
    now
  );
  assert.deepEqual(result, {
    idle: true,
    move: true,
    specialUse: false,
    condstore: false,
    checkedAt: now.toISOString()
  });
});

test("reports no IDLE when the server does not advertise it", () => {
  const result = detectImapCapabilities(new Map([["IMAP4REV1", true]]));
  assert.equal(result.idle, false);
});
