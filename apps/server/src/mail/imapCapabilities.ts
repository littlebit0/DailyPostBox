import type { IncomingCapabilities } from "../domain/types.js";

/** Reads the post-login CAPABILITY set exposed by imapflow (`client.capabilities`). */
export function detectImapCapabilities(
  capabilities: ReadonlyMap<string, unknown>,
  now = new Date()
): IncomingCapabilities {
  const has = (name: string) => capabilities.has(name);
  return {
    idle: has("IDLE"),
    move: has("MOVE"),
    specialUse: has("SPECIAL-USE"),
    condstore: has("CONDSTORE"),
    checkedAt: now.toISOString()
  };
}
