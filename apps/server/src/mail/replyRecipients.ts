import type {
  IncomingMessageContent,
  IncomingMessageSummary,
  MailAccount
} from "../domain/types.js";

const unique = (addresses: string[]) => {
  const seen = new Set<string>();
  return addresses.filter((address) => {
    const key = address.toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
};

// Reply goes to Reply-To (else From); reply-all adds the original To/Cc,
// minus the receiving account's own address.
export function replyFields(
  message: Pick<IncomingMessageSummary, "from">,
  content: Pick<IncomingMessageContent, "thread">,
  account: Pick<MailAccount, "emailAddress">
) {
  const thread = content.thread;
  const own = account.emailAddress.toLowerCase();
  const others = (list: string[]) => list.filter((a) => a.toLowerCase() !== own);
  const sender = message.from.split(",").map((a) => a.trim()).filter(Boolean);
  const replyTo = thread?.replyTo.length ? thread.replyTo : sender;
  const to = unique(others([...replyTo, ...(thread?.to ?? [])]));
  const toKeys = new Set(to.map((a) => a.toLowerCase()));
  const cc = unique(others(thread?.cc ?? [])).filter(
    (a) => !toKeys.has(a.toLowerCase())
  );

  return {
    messageId: thread?.messageId,
    references: thread?.references ?? [],
    replyTo: unique(replyTo),
    replyAllTo: to.length > 0 ? to : unique(replyTo),
    replyAllCc: cc
  };
}
