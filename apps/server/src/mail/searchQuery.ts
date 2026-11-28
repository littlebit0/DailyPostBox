import type { SearchObject } from "imapflow";

export interface ParsedSearchQuery {
  from?: string;
  subject?: string;
  after?: Date;
  before?: Date;
  text?: string;
}

export class SearchQueryError extends Error {}

// Tokens are `key:value`, `key:"quoted value"`, `"quoted text"` or a bare word.
const tokenPattern = /(?:(\w+):)?(?:"([^"]*)"|(\S+))/g;

function parseDate(value: string): Date {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  const date = match
    ? new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])))
    : null;
  if (!date || Number.isNaN(date.getTime()) ||
      date.toISOString().slice(0, 10) !== value) {
    throw new SearchQueryError(`Invalid date: ${value} (use YYYY-MM-DD)`);
  }
  return date;
}

export function parseSearchQuery(query: string): ParsedSearchQuery {
  const parsed: ParsedSearchQuery = {};
  const words: string[] = [];

  for (const match of query.matchAll(tokenPattern)) {
    const key = match[1]?.toLowerCase();
    const value = match[2] ?? match[3] ?? "";
    switch (key) {
      case "from":
        parsed.from = value;
        break;
      case "subject":
        parsed.subject = value;
        break;
      case "after":
        parsed.after = parseDate(value);
        break;
      case "before":
        parsed.before = parseDate(value);
        break;
      default:
        // Unknown `key:` is left as text, e.g. a URL or time like 10:30.
        words.push(key ? `${match[1]}:${value}` : value);
    }
  }

  const text = words.join(" ").trim();
  if (text) parsed.text = text;
  if (!parsed.from && !parsed.subject && !parsed.after && !parsed.before &&
      !parsed.text) {
    throw new SearchQueryError("Search query is empty");
  }
  return parsed;
}

// Plain text matches the subject OR the sender; every other condition is ANDed.
export function toImapSearch(parsed: ParsedSearchQuery): SearchObject {
  const search: SearchObject = {};
  if (parsed.from) search.from = parsed.from;
  if (parsed.subject) search.subject = parsed.subject;
  if (parsed.after) search.since = parsed.after;
  if (parsed.before) search.before = parsed.before;
  if (parsed.text) {
    search.or = [{ subject: parsed.text }, { from: parsed.text }];
  }
  return search;
}
