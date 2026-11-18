import type { MailAccount } from "../domain/types.js";

// Credential failures cannot recover by retrying; callers stop reconnecting
// and ask the user to reconnect the account instead.
export function isAuthenticationFailure(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;

  const candidate = error as {
    authenticationFailed?: boolean;
    code?: unknown;
  };
  // EAUTH: nodemailer's SMTP login rejection.
  return candidate.authenticationFailed === true ||
    candidate.code === "AUTHENTICATIONFAILED" ||
    candidate.code === "EAUTH";
}

export function authenticationFailure(message: string): Error {
  return Object.assign(new Error(message), { authenticationFailed: true });
}

export function applySyncFailure(account: MailAccount, error: unknown): void {
  account.syncStatus = "error";
  account.syncError = error instanceof Error ? error.message : String(error);
  account.syncErrorCode = isAuthenticationFailure(error)
    ? "authentication"
    : undefined;
}
