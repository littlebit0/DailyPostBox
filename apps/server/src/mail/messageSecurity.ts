import type { MessageSecurity } from "../domain/types.js";

interface StructureNode {
  type: string;
  parameters?: { [key: string]: string };
  childNodes?: StructureNode[];
}

// Only detects the MIME shape of signed/encrypted mail. Signature
// verification is not implemented, so `verified` is always false.
export function detectMessageSecurity(root: StructureNode): MessageSecurity {
  let signed: MessageSecurity["signed"] = null;
  let encrypted: MessageSecurity["encrypted"] = null;

  const visit = (node: StructureNode): void => {
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
      if (smimeType === "signed-data") signed ??= "smime";
      else encrypted ??= "smime";
    }
    for (const child of node.childNodes ?? []) visit(child);
  };

  visit(root);
  return { signed, encrypted, verified: false };
}
