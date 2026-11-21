import type { ListUnsubscribe } from "../domain/types.js";

const emailPattern = /^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]+$/;

// Parses RFC 2369 List-Unsubscribe and the RFC 8058 List-Unsubscribe-Post
// headers. Only http(s) URLs and a single mailto address are kept.
export function parseListUnsubscribe(
  listUnsubscribe: string | undefined,
  listUnsubscribePost?: string
): ListUnsubscribe | undefined {
  if (!listUnsubscribe) return undefined;

  const result: ListUnsubscribe = { oneClick: false };
  for (const match of listUnsubscribe.matchAll(/<([^<>]*)>/g)) {
    const value = match[1].replace(/\s+/g, "");
    if (!result.url && /^https?:\/\//i.test(value) && isValidUrl(value)) {
      result.url = value;
    } else if (!result.mailto && /^mailto:/i.test(value)) {
      result.mailto = parseMailto(value);
    }
  }
  if (!result.url && !result.mailto) return undefined;

  result.oneClick = Boolean(
    result.url && /List-Unsubscribe=One-Click/i.test(listUnsubscribePost ?? "")
  );
  return result;
}

function isValidUrl(value: string): boolean {
  try {
    new URL(value);
    return true;
  } catch {
    return false;
  }
}

function parseMailto(value: string): ListUnsubscribe["mailto"] {
  const rest = value.slice("mailto:".length);
  const [rawAddress, query = ""] = rest.split("?", 2);
  let address: string;
  try {
    address = decodeURIComponent(rawAddress).split(",")[0].trim();
  } catch {
    return undefined;
  }
  if (!emailPattern.test(address)) return undefined;

  const params = new URLSearchParams(query);
  return {
    address,
    subject: params.get("subject") ?? undefined,
    body: params.get("body") ?? undefined
  };
}

// Reads a header value out of a raw RFC 5322 header block, unfolding lines.
export function readHeader(raw: string, name: string): string | undefined {
  const unfolded = raw.replace(/\r?\n[ \t]+/g, " ");
  const line = unfolded
    .split(/\r?\n/)
    .find((item) => item.toLowerCase().startsWith(`${name.toLowerCase()}:`));
  return line?.slice(name.length + 1).trim();
}
