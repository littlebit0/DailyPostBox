import type { SentRecipient } from "../workers/AccountRepository.js";

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

// Only addresses the user has sent to: inbound `From` is attacker-controlled and must not be suggested.
// shortcut: no display names or saved address book; add them when the server stores them.
export function suggestContacts(
  recipients: SentRecipient[],
  query: string,
  limit = 8
): ContactSuggestion[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return [];

  const stats = new Map<string, { count: number; last: Date }>();
  for (const recipient of recipients) {
    const address = recipient.address;
    if (!address.includes(needle) || isNonRepliable(address)) continue;
    const current = stats.get(address);
    stats.set(address, {
      count: (current?.count ?? 0) + recipient.count,
      last: current && current.last > recipient.lastSentAt ? current.last : recipient.lastSentAt
    });
  }

  return [...stats.entries()]
    .sort(([, a], [, b]) => b.count - a.count || b.last.getTime() - a.last.getTime())
    .slice(0, limit)
    .map(([address, { count, last }]) => ({ address, count, lastSeenAt: last.toISOString() }));
}
