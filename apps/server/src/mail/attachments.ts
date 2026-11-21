import type { MessageStructureObject } from "imapflow";
import type { IncomingMessageAttachment } from "../domain/types.js";

// imapflow already decodes RFC 2231 / encoded-word names in the parameters.
export function extractAttachments(
  root: MessageStructureObject
): IncomingMessageAttachment[] {
  const found: IncomingMessageAttachment[] = [];

  const visit = (node: MessageStructureObject): void => {
    for (const child of node.childNodes ?? []) visit(child);
    if (node.childNodes?.length || !node.part) return;

    const filename =
      node.dispositionParameters?.filename ?? node.parameters?.name;
    if (node.disposition?.toLowerCase() !== "attachment" && !filename) return;

    found.push({
      part: node.part,
      filename: filename || `attachment-${node.part}`,
      contentType: node.type.toLowerCase(),
      size: node.size ?? 0
    });
  };

  visit(root);
  return found;
}
