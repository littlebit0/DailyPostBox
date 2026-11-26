import assert from "node:assert/strict";
import test from "node:test";
import { NoopPushNotifier } from "../src/notifications/PushNotifier.js";

test("the noop notifier logs no mail content", async (context) => {
  const logged: unknown[][] = [];
  context.mock.method(console, "info", (...args: unknown[]) => {
    logged.push(args);
  });

  await new NoopPushNotifier().notifyNewMessage([], {
    accountId: "account-1",
    providerMessageId: "7",
    mailbox: "INBOX",
    from: "sender@example.com",
    subject: "private subject",
    receivedAt: new Date(),
    hasAttachments: false
  });

  const output = JSON.stringify(logged);
  assert.equal(logged.length, 1);
  assert.ok(!output.includes("private subject"));
  assert.ok(!output.includes("sender@example.com"));
});
