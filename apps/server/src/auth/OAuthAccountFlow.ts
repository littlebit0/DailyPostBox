import { createHash, randomBytes, randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { AccountRepository } from "../workers/AccountRepository.js";
import type {
  AuthMode,
  MailAccount,
  MailProtocol,
  ProviderId
} from "../domain/types.js";
import { env } from "../config/env.js";
import { getProvider } from "../providers/providerRegistry.js";

type SessionStatus = "waiting" | "authenticated" | "completed" | "error";

interface OAuthSession {
  state: string;
  providerId: ProviderId;
  emailAddress?: string;
  incomingProtocol?: MailProtocol;
  initialSync?: MailAccount["initialSync"];
  codeVerifier: string;
  token?: OAuthTokenResponse;
  status: SessionStatus;
  error?: string;
  accountId?: string;
  createdAt: Date;
}

interface OAuthTokenResponse {
  access_token?: string;
  refresh_token?: string;
  expires_in?: number;
  token_type?: string;
  scope?: string;
  id_token?: string;
  error?: string;
  error_description?: string;
}

const finishSchema = z.object({
  incomingProtocol: z.enum(["imap", "pop3"]).default("imap"),
  initialSync: z.object({
    includePreviousMessages: z.boolean(),
    limit: z.union([z.number().int().positive(), z.literal("all")])
  }).default({
    includePreviousMessages: true,
    limit: 100
  })
});

export class OAuthAccountFlow {
  private readonly sessions = new Map<string, OAuthSession>();

  constructor(
    private readonly deps: {
      accounts: AccountRepository;
      validateAccount: (account: MailAccount) => Promise<void>;
      startAccountSync: (account: MailAccount) => Promise<void>;
    }
  ) {}

  register(app: FastifyInstance): void {
    app.post("/auth/:providerId/start", async (request, reply) => {
      const params = z.object({
        providerId: z.enum(["gmail", "outlook"])
      }).parse(request.params);
      const provider = getProvider(params.providerId);

      if (!provider.oauth) {
        return reply.code(400).send({
          error: `${provider.displayName} does not support browser login.`
        });
      }

      const clientId = this.clientIdFor(params.providerId);
      if (!clientId) {
        return reply.code(400).send({
          error:
            `${provider.displayName} 브라우저 로그인을 사용하려면 OAuth client id 설정이 필요합니다.`
        });
      }

      const state = randomUUID();
      const codeVerifier = base64Url(randomBytes(48));
      const session: OAuthSession = {
        state,
        providerId: params.providerId,
        codeVerifier,
        status: "waiting",
        createdAt: new Date()
      };
      this.sessions.set(state, session);

      const authorizationUrl = new URL(provider.oauth.authorizationUrl);
      authorizationUrl.searchParams.set("client_id", clientId);
      authorizationUrl.searchParams.set("redirect_uri", this.redirectUri(params.providerId));
      authorizationUrl.searchParams.set("response_type", "code");
      authorizationUrl.searchParams.set("scope", provider.oauth.scopes.join(" "));
      authorizationUrl.searchParams.set("state", state);
      authorizationUrl.searchParams.set("code_challenge", codeChallenge(codeVerifier));
      authorizationUrl.searchParams.set("code_challenge_method", "S256");
      if (params.providerId === "gmail") {
        authorizationUrl.searchParams.set("access_type", "offline");
        authorizationUrl.searchParams.set("prompt", "consent");
      }

      return {
        state,
        authorizationUrl: authorizationUrl.toString(),
        expiresAt: new Date(Date.now() + 10 * 60_000).toISOString()
      };
    });

    app.get("/auth/sessions/:state", async (request, reply) => {
      const params = z.object({ state: z.string() }).parse(request.params);
      const session = this.sessions.get(params.state);
      if (!session) return reply.code(404).send({ error: "Login session not found" });
      return {
        state: session.state,
        status: session.status,
        error: session.error,
        accountId: session.accountId,
        emailAddress: session.emailAddress
      };
    });

    app.post("/auth/sessions/:state/complete", async (request, reply) => {
      const params = z.object({ state: z.string() }).parse(request.params);
      const options = finishSchema.parse(request.body);
      const session = this.sessions.get(params.state);

      if (!session) return reply.code(404).send({ error: "Login session not found" });
      if (session.status === "completed" && session.accountId) {
        return { accountId: session.accountId };
      }
      if (session.status !== "authenticated" || !session.token || !session.emailAddress) {
        return reply.code(409).send({ error: "브라우저 로그인을 먼저 완료하세요." });
      }

      try {
        const account = await this.createAccount(session, options.incomingProtocol, options.initialSync);
        session.status = "completed";
        session.accountId = account.id;
        return { accountId: account.id };
      } catch (error) {
        session.status = "error";
        session.error = error instanceof Error ? error.message : String(error);
        return reply.code(400).send({ error: session.error });
      }
    });

    app.get("/auth/:providerId/callback", async (request, reply) => {
      const params = z.object({
        providerId: z.enum(["gmail", "outlook"])
      }).parse(request.params);
      const query = z.object({
        code: z.string().optional(),
        state: z.string(),
        error: z.string().optional()
      }).parse(request.query);
      const session = this.sessions.get(query.state);

      if (!session || session.providerId !== params.providerId) {
        return reply.type("text/html").send(renderResultPage("로그인 세션을 찾을 수 없습니다."));
      }

      if (query.error || !query.code) {
        session.status = "error";
        session.error = query.error ?? "Authorization code was not returned.";
        return reply.type("text/html").send(renderResultPage(session.error));
      }

      try {
        const token = await this.exchangeCode(params.providerId, query.code, session);
        if (!token.access_token) {
          throw new Error(token.error_description ?? token.error ?? "Access token was not returned.");
        }

        const emailAddress = emailFromIdToken(token.id_token);
        if (!emailAddress) throw new Error("로그인한 이메일 주소를 확인하지 못했습니다. 다른 계정으로 다시 시도하세요.");

        session.emailAddress = emailAddress;
        session.token = token;
        session.status = "authenticated";
        return reply.type("text/html").send(renderResultPage(null));
      } catch (error) {
        session.status = "error";
        session.error = error instanceof Error ? error.message : String(error);
        return reply.type("text/html").send(renderResultPage(session.error));
      }
    });
  }

  private async exchangeCode(
    providerId: "gmail" | "outlook",
    code: string,
    session: OAuthSession
  ): Promise<OAuthTokenResponse> {
    const provider = getProvider(providerId);
    const clientId = this.clientIdFor(providerId);
    if (!clientId || !provider.oauth) throw new Error("OAuth provider is not configured.");

    const body = new URLSearchParams({
      client_id: clientId,
      code,
      code_verifier: session.codeVerifier,
      grant_type: "authorization_code",
      redirect_uri: this.redirectUri(providerId)
    });
    const clientSecret = this.clientSecretFor(providerId);
    if (clientSecret) body.set("client_secret", clientSecret);

    const response = await fetch(provider.oauth.tokenUrl, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body
    });
    const payload = await response.json() as OAuthTokenResponse;
    if (!response.ok) {
      throw new Error(payload.error_description ?? payload.error ?? "OAuth token exchange failed.");
    }
    return payload;
  }

  private async createAccount(
    session: OAuthSession,
    incomingProtocol: MailProtocol,
    initialSync: NonNullable<MailAccount["initialSync"]>
  ): Promise<MailAccount> {
    const token = session.token!;
    const now = new Date();
    const existingAccounts = await this.deps.accounts.listActiveAccounts();
    const duplicate = existingAccounts.some(
      (account) => account.userId === "demo-user" &&
        account.providerId === session.providerId &&
        account.emailAddress.toLowerCase() === session.emailAddress!.toLowerCase()
    );
    if (duplicate) {
      throw new Error("이미 연결된 이메일 계정입니다.");
    }

    const account: MailAccount = {
      id: randomUUID(),
      userId: "demo-user",
      providerId: session.providerId,
      emailAddress: session.emailAddress!,
      authMode: "oauth2" as AuthMode,
      incomingProtocol,
      encryptedSecretRef: JSON.stringify({
        type: "oauth2",
        accessToken: token.access_token,
        refreshToken: token.refresh_token,
        expiresAt: token.expires_in
          ? new Date(Date.now() + token.expires_in * 1000).toISOString()
          : undefined,
        scope: token.scope
      }),
      syncStatus: "validating",
      initialSync,
      createdAt: now,
      updatedAt: now
    };

    await this.deps.validateAccount(account);
    account.syncStatus = "syncing";
    await this.deps.accounts.addAccount(account);
    void this.deps.startAccountSync(account);
    return account;
  }

  private redirectUri(providerId: ProviderId): string {
    return `${env.OAUTH_REDIRECT_BASE_URL}/auth/${providerId}/callback`;
  }

  private clientIdFor(providerId: ProviderId): string | undefined {
    if (providerId === "gmail") return env.GOOGLE_OAUTH_CLIENT_ID;
    if (providerId === "outlook") return env.OUTLOOK_OAUTH_CLIENT_ID;
    return undefined;
  }

  private clientSecretFor(providerId: ProviderId): string | undefined {
    if (providerId === "gmail") return env.GOOGLE_OAUTH_CLIENT_SECRET;
    if (providerId === "outlook") return env.OUTLOOK_OAUTH_CLIENT_SECRET;
    return undefined;
  }
}

function codeChallenge(codeVerifier: string): string {
  return base64Url(createHash("sha256").update(codeVerifier).digest());
}

function base64Url(value: Buffer): string {
  return value
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function renderResultPage(error: string | null): string {
  const title = error ? "로그인 실패" : "로그인 완료";
  const body = error
    ? `계정 연결에 실패했습니다.<br><pre>${escapeHtml(error)}</pre>`
    : "계정 연결이 완료되었습니다. 이제 앱으로 돌아가세요.";

  return `<!doctype html>
<html lang="ko">
  <head>
    <meta charset="utf-8" />
    <title>${title}</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 48px; line-height: 1.5; }
      pre { white-space: pre-wrap; color: #b3261e; }
    </style>
  </head>
  <body>
    <h1>${title}</h1>
    <p>${body}</p>
  </body>
</html>`;
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (char) => {
    const entities: Record<string, string> = {
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      "\"": "&quot;",
      "'": "&#39;"
    };
    return entities[char] ?? char;
  });
}

function emailFromIdToken(idToken: string | undefined): string | undefined {
  if (!idToken) return undefined;
  const payload = idToken.split(".")[1];
  if (!payload) return undefined;
  try {
    const parsed = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as {
      email?: unknown;
      preferred_username?: unknown;
      upn?: unknown;
    };
    const candidate = parsed.email ?? parsed.preferred_username ?? parsed.upn;
    return typeof candidate === "string" && z.string().email().safeParse(candidate).success
      ? candidate
      : undefined;
  } catch {
    return undefined;
  }
}
