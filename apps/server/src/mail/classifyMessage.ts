export type MessageCategory = "person" | "notification" | "newsletter";

export const classificationHeaderNames = [
  "list-unsubscribe",
  "list-id",
  "precedence",
  "auto-submitted"
];

// Parses a raw RFC 5322 header block into lowercase-name -> value (folded lines joined).
export function parseRawHeaders(raw: Buffer | string | undefined): Record<string, string> {
  const headers: Record<string, string> = {};
  if (!raw) return headers;
  const unfolded = raw.toString("utf8").replace(/\r?\n[ \t]+/g, " ");
  for (const line of unfolded.split(/\r?\n/)) {
    const index = line.indexOf(":");
    if (index <= 0) continue;
    headers[line.slice(0, index).trim().toLowerCase()] = line.slice(index + 1).trim();
  }
  return headers;
}

const automatedLocalPart =
  /^(no[-_.]?reply|do[-_.]?not[-_.]?reply|notifications?|alerts?|mailer-daemon|postmaster|bounces?)([-_.+].*)?$/i;

export function classifyMessage(
  headers: Record<string, string>,
  from: string
): MessageCategory {
  const autoSubmitted = headers["auto-submitted"]?.toLowerCase();
  if (autoSubmitted && autoSubmitted !== "no") return "notification";

  const precedence = headers["precedence"]?.toLowerCase();
  if (
    headers["list-unsubscribe"] ||
    headers["list-id"] ||
    (precedence && ["bulk", "list", "junk"].includes(precedence))
  ) {
    return "newsletter";
  }

  const localPart = from.split(",")[0]?.split("@")[0]?.trim() ?? "";
  if (automatedLocalPart.test(localPart)) return "notification";
  return "person";
}
