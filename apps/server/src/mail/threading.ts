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
  return root ? `mid:${root}` : undefined;
}

export function parseMessageIds(value: string | undefined): string[] {
  return value?.match(/<[^<>\s]+>/g) ?? [];
}

// Adds threadId and a per-thread message count to each summary.
export function withThreadInfo<T extends IncomingMessageSummary>(
  messages: T[]
): Array<T & { threadId?: string; threadCount: number }> {
  const withIds = messages.map((message) => ({
    ...message,
    threadId: computeThreadId(message)
  }));
  const counts = new Map<string, number>();
  for (const { threadId } of withIds) {
    if (threadId) counts.set(threadId, (counts.get(threadId) ?? 0) + 1);
  }
  return withIds.map((message) => ({
    ...message,
    threadCount: message.threadId ? counts.get(message.threadId)! : 1
  }));
}
