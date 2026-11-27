import type { MessageSecurity } from "../domain/types.js";

interface StructureNode {
  type: string;
  parameters?: { [key: string]: string };
  disposition?: string;
  dispositionParameters?: { [key: string]: string };
  childNodes?: StructureNode[];
}

// Only detects the MIME shape of signed/encrypted mail. Signature
// verification is not implemented, so `verified` is always false.
export function detectMessageSecurity(root: StructureNode): MessageSecurity {
  type State = Pick<MessageSecurity, "signed" | "encrypted">;
  const any: State = { signed: null, encrypted: null };
  // Security around each text part selectBodyParts may display.
  const bodyStates: State[] = [];

  // `wrapper` marks the root and the parts of a multipart/signed or
  // multipart/encrypted reached through it: RFC 8551 sends those with
  // `disposition: attachment` (smime.p7m/p7s), yet they wrap this message.
  const visit = (node: StructureNode, wrapper: boolean, outer: State): void => {
    let signed = outer.signed;
    let encrypted = outer.encrypted;
    // Other attachments are not the displayed body, so their security does
    // not describe this message (matches selectBodyParts in ImapReceiver).
    if (!wrapper && node.disposition?.toLowerCase() === "attachment") return;
    const type = node.type.toLowerCase();
    const protocol = node.parameters?.protocol?.toLowerCase();
    const smimeType = node.parameters?.["smime-type"]?.toLowerCase();

    if (type === "multipart/signed") {
      if (protocol === "application/pgp-signature") signed ??= "openpgp";
      else if (
        protocol === "application/pkcs7-signature" ||
        protocol === "application/x-pkcs7-signature"
      ) signed ??= "smime";
    } else if (type === "multipart/encrypted") {
      if (protocol === "application/pgp-encrypted") encrypted ??= "openpgp";
    } else if (
      type === "application/pkcs7-mime" ||
      type === "application/x-pkcs7-mime"
    ) {
      const name = (
        node.parameters?.name ?? node.dispositionParameters?.filename ?? ""
      ).toLowerCase();
      if (smimeType === "signed-data") signed ??= "smime";
      else if (
        smimeType === "enveloped-data" ||
        smimeType === "authenveloped-data" ||
        (smimeType === undefined && name.endsWith(".p7m"))
      ) encrypted ??= "smime";
    }
    any.signed ??= signed;
    any.encrypted ??= encrypted;
    if (type === "text/plain" || type === "text/html") bodyStates.push({ signed, encrypted });
    const wrapsChildren = type === "multipart/signed" || type === "multipart/encrypted";
    for (const child of node.childNodes ?? []) visit(child, wrapsChildren, { signed, encrypted });
  };

  visit(root, true, { signed: null, encrypted: null });
  // No readable text (opaque S/MIME, PGP/MIME encrypted): report the wrapper.
  if (bodyStates.length === 0) return { ...any, verified: false };
  // Only a wrapper enclosing every displayable text part describes the body;
  // unsigned text beside a signed part must not be shown as signed.
  const all = <K extends keyof State>(key: K): State[K] =>
    bodyStates.every((state) => state[key] !== null) ? bodyStates[0][key] : null;
  return { signed: all("signed"), encrypted: all("encrypted"), verified: false };
}
