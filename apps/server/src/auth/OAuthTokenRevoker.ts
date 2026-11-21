import type { MailAccount } from "../domain/types.js";
import type { SecretResolver } from "../security/SecretResolver.js";

export type RevokeResult = "revoked" | "skipped" | "unsupported" | "failed";

const googleRevokeUrl = "https://oauth2.googleapis.com/revoke";

// Best effort: a failure must never block deleting the account's local data.
// Microsoft identity platform v2 has no token revocation endpoint, so Outlook
// reports "unsupported" and the user removes access in their account settings.
export class OAuthTokenRevoker {
  constructor(
    private readonly secrets: SecretResolver,
    private readonly fetchImpl: typeof fetch = fetch,
    // Must stay well under the client's 30s receive timeout.
    private readonly timeoutMs = 10_000
  ) {}

  async revoke(account: MailAccount): Promise<RevokeResult> {
    if (account.authMode !== "oauth2") return "skipped";
    if (account.providerId === "outlook") return "unsupported";
    if (account.providerId !== "gmail") return "skipped";

    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), this.timeoutMs);
    try {
      const raw = await this.secrets.resolve(account.encryptedSecretRef);
      const payload = JSON.parse(raw) as { refreshToken?: string; accessToken?: string };
      const token = payload.refreshToken ?? payload.accessToken;
      if (!token) return "skipped";

      const response = await this.fetchImpl(googleRevokeUrl, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ token }),
        signal: abort.signal
      });
      // 400 invalid_token: already revoked or expired, so access is gone anyway.
      return response.ok || response.status === 400 ? "revoked" : "failed";
    } catch {
      return "failed";
    } finally {
      clearTimeout(timer);
    }
  }
}
