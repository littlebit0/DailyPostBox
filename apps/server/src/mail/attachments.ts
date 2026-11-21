import type { MessageStructureObject } from "imapflow";
import type { IncomingMessageAttachment } from "../domain/types.js";

// imapflow already decodes RFC 2231 / encoded-word names in the parameters.
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

    // An attached message carries child parts, but the message itself is the attachment.
    if (node.part && isAttachment && (!hasChildren || type === "message/rfc822")) {
      found.push({
        part: node.part,
        filename:
          filename ||
          `attachment-${node.part}${type === "message/rfc822" ? ".eml" : ""}`,
        contentType: type,
        size: node.size ?? 0
      });
      return;
    }
    for (const child of node.childNodes ?? []) visit(child);
  };

  visit(root);
  return found;
}
