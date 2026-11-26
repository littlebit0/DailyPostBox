import type { MailAccount } from "../domain/types.js";
import { getProvider } from "./providerRegistry.js";

export function resolveIncomingSettings(account: MailAccount) {
  const provider = getProvider(account.providerId);
  return {
    ...provider.incoming,
    ...account.connectionOverride?.incoming
  };
}

export function resolveOutgoingSettings(account: MailAccount) {
  const provider = getProvider(account.providerId);
  return {
    ...provider.outgoing,
    ...account.connectionOverride?.outgoing
  };
}

// Account overrides win: a custom server may support IDLE even though the
// generic custom provider entry does not assume it.
export function supportsImapIdle(account: MailAccount): boolean {
  return account.incomingProtocol === "imap" &&
    resolveIncomingSettings(account).supportsIdle === true;
}
