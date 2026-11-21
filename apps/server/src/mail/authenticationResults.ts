import type {
  AuthenticationFailure,
  ProviderId
} from "../domain/types.js";

// shortcut: only providers whose authserv-id is confirmed; naver/daum/custom are ignored until their header format is verified.
const trustedAuthservIds: Partial<Record<ProviderId, (id: string) => boolean>> = {
  gmail: (id) => id === "mx.google.com",
  outlook: (id) => id.endsWith(".protection.outlook.com")
};

/**
 * Reads raw header text and returns failures reported by the provider's own
 * server. Only the topmost Authentication-Results header is considered: the
 * receiving server prepends its own, so lower ones may be sender-forged.
 */
export function parseAuthenticationFailures(
  rawHeaders: string,
  providerId: ProviderId
): AuthenticationFailure[] {
  const isTrusted = trustedAuthservIds[providerId];
  if (!isTrusted) return [];

  const unfolded = rawHeaders.replace(/\r?\n[ \t]+/g, " ");
  const line = unfolded
    .split(/\r?\n/)
    .find((item) => /^authentication-results\s*:/i.test(item));
  if (!line) return [];

  const value = line
    .replace(/^[^:]*:/, "")
    .replace(/\([^)]*\)/g, " ")
    .trim();
  const [head, ...rest] = value.split(";");
  const authservId = head.trim().split(/\s+/)[0]?.toLowerCase();
  // Outlook's documented format omits the authserv-id (starts with `spf=fail ...`), so the topmost header is trusted without one.
  const outlookNoId =
    providerId === "outlook" && /^[a-z0-9-]+=/.test(authservId ?? "");
  if (!authservId || !(outlookNoId || isTrusted(authservId))) return [];
  const clauses = outlookNoId ? [head, ...rest] : rest;

  const results = new Map<string, string[]>();
  for (const clause of clauses) {
    const match = clause.trim().match(/^([a-z0-9-]+)\s*=\s*([a-z]+)/i);
    if (!match) continue;
    const method = match[1].toLowerCase();
    results.set(method, [
      ...(results.get(method) ?? []),
      match[2].toLowerCase()
    ]);
  }

  const has = (method: string, result: string) =>
    results.get(method)?.includes(result) ?? false;

  // A passing DMARC means the message is aligned; stray SPF/DKIM failures are noise.
  if (has("dmarc", "pass")) return [];

  const failures: AuthenticationFailure[] = [];
  if (has("dmarc", "fail")) failures.push("dmarc");
  if (has("spf", "fail")) failures.push("spf");
  if (has("dkim", "fail") && !has("dkim", "pass")) failures.push("dkim");
  return failures;
}
