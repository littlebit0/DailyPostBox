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
