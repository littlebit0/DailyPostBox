import type { MessageStructureObject } from "imapflow";
import type { IncomingMessageAttachment } from "../domain/types.js";

// imapflow already decodes RFC 2231 / encoded-word names in the parameters.
// IMAP BODYSTRUCTURE size is the transfer-encoded size; estimate the decoded size for base64.
// shortcut: assumes 76-char lines + CRLF, quoted-printable keeps the encoded size.
export function estimateDecodedSize(size: number, encoding?: string): number {
  if (encoding?.toLowerCase() !== "base64") return size;
  return Math.floor(((size - Math.floor(size / 78) * 2) * 3) / 4);
}

export function extractAttachments(
  root: MessageStructureObject
): IncomingMessageAttachment[] {
  const found: IncomingMessageAttachment[] = [];

  const visit = (node: MessageStructureObject): void => {
    const filename =
      node.dispositionParameters?.filename ?? node.parameters?.name;
    const isAttachment =
      node.disposition?.toLowerCase() === "attachment" || Boolean(filename);
    const type = node.type.toLowerCase();
    const hasChildren = Boolean(node.childNodes?.length);
    // ImapFlow gives a single-part message root no part number; its body is part "1".
    const part = node.part ?? (node === root && !hasChildren ? "1" : undefined);

    // An attached message carries child parts, but the message itself is the attachment.
    if (part && isAttachment && (!hasChildren || type === "message/rfc822")) {
      found.push({
        part,
        filename:
          filename ||
          `attachment-${part}${type === "message/rfc822" ? ".eml" : ""}`,
        contentType: type,
        size: estimateDecodedSize(node.size ?? 0, node.encoding)
      });
      return;
    }
    for (const child of node.childNodes ?? []) visit(child);
  };

  visit(root);
  return found;
}

function findPart(
  root: MessageStructureObject,
  part: string
): MessageStructureObject | undefined {
  if (part === "1" && !root.part && !root.childNodes?.length) return root;
  if (root.part === part) return root;
  for (const child of root.childNodes ?? []) {
    const found = findPart(child, part);
    if (found) return found;
  }
  return undefined;
}

// ImapFlow download() converts inline/undisposed text parts to UTF-8 and
// unwraps format=flowed (imapflow 1.4.3 lib/imap-flow.js), which alters the
// file. For those types, return the raw BODY[] key and its transfer encoding
// so the caller fetches and decodes the original bytes itself.
export function rawAttachmentFetch(
  root: MessageStructureObject,
  part: string
): { key: string; encoding?: string } | null {
  const node = findPart(root, part);
  const type = node?.type.toLowerCase();
  if (!node || !["text/plain", "text/html", "text/x-amp-html"].includes(type!)) {
    return null;
  }
  return {
    key: node === root && !root.part ? "text" : part,
    encoding: node.encoding?.toLowerCase()
  };
}

export function decodeTransferEncoding(raw: Buffer, encoding?: string): Buffer {
  if (encoding === "base64") return Buffer.from(raw.toString("latin1"), "base64");
  if (encoding !== "quoted-printable") return raw;
  const decoded = raw
    .toString("latin1")
    .replace(/=\r?\n/g, "")
    .replace(/=([0-9A-Fa-f]{2})/g, (_, hex: string) =>
      String.fromCharCode(parseInt(hex, 16))
    );
  return Buffer.from(decoded, "latin1");
}
