import type { MailAccount, ProviderId } from "../domain/types.js";
import { env } from "../config/env.js";
import { getProvider } from "../providers/providerRegistry.js";
import type { SecretResolver } from "../security/SecretResolver.js";
import type { AccountRepository } from "../workers/AccountRepository.js";

interface StoredOAuthSecret {
  type: "oauth2";
  accessToken: string;
  refreshToken?: string;
  expiresAt?: string;
  scope?: string;
}

interface RefreshTokenResponse {
  access_token?: string;
  refresh_token?: string;
  expires_in?: number;
  scope?: string;
  error?: string;
  error_description?: string;
}

export class OAuthTokenManager {
  private readonly refreshes = new Map<string, Promise<string>>();

  constructor(
    private readonly secrets: SecretResolver,
    private readonly accounts: AccountRepository
  ) {}

  async accessTokenFor(
    account: MailAccount,
    encryptedSecretRef = account.encryptedSecretRef
  ): Promise<string | null> {
    const rawSecret = await this.secrets.resolve(encryptedSecretRef);
    const oauth = parseStoredOAuthSecret(rawSecret);
    if (!oauth) return null;
    if (!shouldRefresh(oauth)) return oauth.accessToken;

    let pending = this.refreshes.get(account.id);
    if (!pending) {
      pending = this.refresh(account, oauth).finally(() => {
        this.refreshes.delete(account.id);
      });
      this.refreshes.set(account.id, pending);
    }
    return pending;
  }

  private async refresh(
    account: MailAccount,
    oauth: StoredOAuthSecret
  ): Promise<string> {
    const provider = getProvider(account.providerId);
    const clientId = clientIdFor(account.providerId);
    if (!provider.oauth || !clientId || !oauth.refreshToken) {
      throw new Error("OAuth session expired. Sign in to the account again.");
    }

    const body = new URLSearchParams({
      client_id: clientId,
      grant_type: "refresh_token",
      refresh_token: oauth.refreshToken
    });
    const clientSecret = clientSecretFor(account.providerId);
    if (clientSecret) body.set("client_secret", clientSecret);

    const response = await fetch(provider.oauth.tokenUrl, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body
    });
    const token = await response.json() as RefreshTokenResponse;
    if (!response.ok || !token.access_token) {
      throw new Error(
        token.error_description ?? token.error ?? "OAuth token refresh failed."
      );
    }

    const refreshed: StoredOAuthSecret = {
      ...oauth,
      accessToken: token.access_token,
      refreshToken: token.refresh_token ?? oauth.refreshToken,
      expiresAt: token.expires_in
        ? new Date(Date.now() + token.expires_in * 1000).toISOString()
        : oauth.expiresAt,
      scope: token.scope ?? oauth.scope
    };
    account.encryptedSecretRef = JSON.stringify(refreshed);
    account.updatedAt = new Date();
    await this.accounts.updateAccount(account);
    return refreshed.accessToken;
  }
}

function parseStoredOAuthSecret(secret: string): StoredOAuthSecret | null {
  try {
    const payload = JSON.parse(secret) as Partial<StoredOAuthSecret>;
    if (payload.type === "oauth2" && payload.accessToken) {
      return payload as StoredOAuthSecret;
    }
  } catch {
    return null;
  }
  return null;
}

function shouldRefresh(secret: StoredOAuthSecret): boolean {
  if (!secret.expiresAt) return false;
  const expiresAt = Date.parse(secret.expiresAt);
  return Number.isFinite(expiresAt) && expiresAt <= Date.now() + 60_000;
}

function clientIdFor(providerId: ProviderId): string | undefined {
  if (providerId === "gmail") return env.GOOGLE_OAUTH_CLIENT_ID;
  if (providerId === "outlook") return env.OUTLOOK_OAUTH_CLIENT_ID;
  return undefined;
}

function clientSecretFor(providerId: ProviderId): string | undefined {
  if (providerId === "gmail") return env.GOOGLE_OAUTH_CLIENT_SECRET;
  if (providerId === "outlook") return env.OUTLOOK_OAUTH_CLIENT_SECRET;
  return undefined;
}
