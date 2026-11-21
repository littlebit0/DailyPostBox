import { createHash } from "node:crypto";
import type { IncomingMessageSummary } from "../domain/types.js";

// Gmail thread id wins; otherwise the first Reference (the conversation root),
// then In-Reply-To, then the message's own id. Subject is never used so that
// unrelated mail with the same subject is not merged.
export function computeThreadId(
  message: Pick<
    IncomingMessageSummary,
    "gmailThreadId" | "messageId" | "inReplyTo" | "references"
  >
): string | undefined {
  if (message.gmailThreadId) return `gm:${message.gmailThreadId}`;
  const root = message.references?.[0] ?? message.inReplyTo ?? message.messageId;
  return root ? midThreadId(root) : undefined;
}

// Hashed so the id stays short enough for a URL path segment (Fastify limits
// params to 100 chars) whatever the Message-ID length.
function midThreadId(root: string): string {
  return `mid:${createHash("sha256").update(root).digest("hex").slice(0, 32)}`;
}

// Without References, follows In-Reply-To through the supplied messages to the
// chain's root so A <- B <- C land in one thread.
function resolveRoot(
  message: Pick<IncomingMessageSummary, "messageId" | "inReplyTo" | "references">,
  byId: Map<string, Pick<IncomingMessageSummary, "messageId" | "inReplyTo" | "references">>
): string | undefined {
  const seen = new Set<string>();
  let current = message;
  let root = current.references?.[0] ?? current.inReplyTo ?? current.messageId;
  while (!current.references?.length && current.inReplyTo && !seen.has(current.inReplyTo)) {
    seen.add(current.inReplyTo);
    const parent = byId.get(current.inReplyTo);
    if (!parent) break;
    current = parent;
    root = current.references?.[0] ?? current.inReplyTo ?? current.messageId;
  }
  return root;
}

export function parseMessageIds(value: string | undefined): string[] {
  return value?.match(/<[^<>\s]+>/g) ?? [];
}

// Adds threadId and a per-thread message count to each summary.
export function withThreadInfo<T extends IncomingMessageSummary>(
  messages: T[]
): Array<T & { threadId?: string; threadCount: number }> {
  const byId = new Map<string, IncomingMessageSummary>();
  for (const message of messages) {
    if (message.messageId) byId.set(message.messageId, message);
  }
  const withIds = messages.map((message) => {
    let threadId = computeThreadId(message);
    if (!message.gmailThreadId) {
      const root = resolveRoot(message, byId);
      threadId = root ? midThreadId(root) : undefined;
    }
    return { ...message, threadId };
  });
  const counts = new Map<string, number>();
  for (const { threadId } of withIds) {
    if (threadId) counts.set(threadId, (counts.get(threadId) ?? 0) + 1);
  }
  return withIds.map((message) => ({
    ...message,
    threadCount: message.threadId ? counts.get(message.threadId)! : 1
  }));
}
