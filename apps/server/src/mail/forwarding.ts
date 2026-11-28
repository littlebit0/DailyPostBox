import type {
  AttachmentDownload,
  IncomingMessageAttachment,
  OutgoingMessageDraft
} from "../domain/types.js";

// Common provider cap on a whole message (Gmail/Outlook: 25 MB); bigger never goes out anyway.
export const maxForwardedBytes = 25 * 1024 * 1024;

/** Picks the requested parts from the original message, or says why it cannot. */
export function selectForwardedAttachments(
  available: IncomingMessageAttachment[],
  parts: string[],
  maxBytes = maxForwardedBytes
): { attachments: IncomingMessageAttachment[] } | { error: string; status: 400 | 413 } {
  if (new Set(parts).size !== parts.length) {
    return { error: "Duplicate attachment part", status: 400 };
  }
  const attachments: IncomingMessageAttachment[] = [];
  for (const part of parts) {
    const found = available.find((item) => item.part === part);
    if (!found) return { error: `Attachment ${part} not found`, status: 400 };
    attachments.push(found);
  }
  const total = attachments.reduce((sum, item) => sum + item.size, 0);
  if (total > maxBytes) return { error: "Forwarded attachments are too large", status: 413 };
  return { attachments };
}

export const originalMessageFilename = "original.eml";

/** Reads each forwarded part (and the whole original when asked) into memory; any missing part or overflow throws so the send fails. */
export async function resolveForwardedAttachments(
  draft: OutgoingMessageDraft,
  download: (part: string) => Promise<AttachmentDownload | null>,
  maxBytes = maxForwardedBytes,
  downloadOriginal?: () => Promise<AttachmentDownload | null>
): Promise<OutgoingMessageDraft> {
  const parts = draft.forwardOf?.parts ?? [];
  const includeOriginal = draft.forwardOf?.includeOriginal === true;
  if (parts.length === 0 && !includeOriginal) return draft;
  const forwardedAttachments: NonNullable<OutgoingMessageDraft["forwardedAttachments"]> = [];
  let total = 0;
  const read = async (file: AttachmentDownload | null, label: string, contentType?: string) => {
    if (!file) throw new Error(`Forwarded ${label} is no longer available`);
    try {
      const chunks: Buffer[] = [];
      for await (const chunk of file.stream as AsyncIterable<Buffer | string>) {
        const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        total += bytes.length;
        if (total > maxBytes) throw new Error("Forwarded attachments are too large");
        chunks.push(bytes);
      }
      forwardedAttachments.push({
        filename: file.filename,
        contentType: contentType ?? file.contentType,
        content: Buffer.concat(chunks)
      });
    } finally {
      await file.close();
    }
  };
  for (const part of parts) {
    await read(await download(part), `attachment ${part}`);
  }
  if (includeOriginal) {
    if (!downloadOriginal) throw new Error("Original message download is unavailable");
    await read(await downloadOriginal(), "original message", "message/rfc822");
  }
  return { ...draft, forwardedAttachments };
}
