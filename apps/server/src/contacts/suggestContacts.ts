import type { IncomingMessageSummary } from "../domain/types.js";

export interface ContactSuggestion {
  address: string;
  count: number;
  lastSeenAt: string;
}

// Local part without `+tag`, with `.`, `_`, `-` removed: noreply+x, no_reply, do-not-reply all collapse to one form.
// shortcut: noreply family matches by prefix (noreply-alerts too); a real user named "noreplyfoo" is dropped.
function isNonRepliable(address: string): boolean {
  const local = address.slice(0, address.lastIndexOf("@")).split("+")[0].replace(/[._-]/g, "");
  return /^(noreply|donotreply|notreply)/.test(local) || /^(mailerdaemon|postmaster|bounces?)$/.test(local);
}

// shortcut: only sender addresses of stored messages (no display names, no sent-mail recipients); add them when summaries store names.
export function suggestContacts(
  messages: IncomingMessageSummary[],
  query: string,
  limit = 8
): ContactSuggestion[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return [];

  const stats = new Map<string, { count: number; last: Date }>();
  for (const message of messages) {
    for (const raw of message.from.split(",")) {
      const address = raw.trim().toLowerCase();
      if (!address.includes("@") || !address.includes(needle) || isNonRepliable(address)) continue;
      const current = stats.get(address);
      stats.set(address, {
        count: (current?.count ?? 0) + 1,
        last: current && current.last > message.receivedAt ? current.last : message.receivedAt
      });
    }
  }

  return [...stats.entries()]
    .sort(([, a], [, b]) => b.count - a.count || b.last.getTime() - a.last.getTime())
    .slice(0, limit)
    .map(([address, { count, last }]) => ({ address, count, lastSeenAt: last.toISOString() }));
}
