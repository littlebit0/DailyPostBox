import { DomUtils, parseDocument } from "htmlparser2";
import type { IncomingMessageLink } from "../domain/types.js";

const allowedSchemes = new Set(["http:", "https:", "mailto:"]);
const maxLinksPerMessage = 200;
const maxLabelLength = 256;
const maxUrlLength = 8192;

export function extractMessageLinks(html: string): IncomingMessageLink[] {
  const document = parseDocument(html);
  const anchors = DomUtils.findAll(
    (element) => element.name.toLowerCase() === "a",
    document
  );
  const links: IncomingMessageLink[] = [];
  const seen = new Set<string>();

  for (const anchor of anchors) {
    if (links.length >= maxLinksPerMessage) break;

    const url = safeLinkUrl(anchor.attribs.href);
    if (!url) continue;

    const label = firstReadableLabel([
      DomUtils.innerText(anchor),
      anchor.attribs["aria-label"],
      anchor.attribs.title,
      url
    ]);
    const key = `${url}\u0000${label}`;
    if (seen.has(key)) continue;

    seen.add(key);
    links.push({ url, label });
  }

  return links;
}

function safeLinkUrl(value: string | undefined): string | null {
  const candidate = value?.trim();
  if (!candidate || candidate.length > maxUrlLength) return null;

  try {
    const parsed = new URL(candidate);
    if (!allowedSchemes.has(parsed.protocol.toLowerCase())) return null;
    if ((parsed.protocol === "http:" || parsed.protocol === "https:") && !parsed.host) {
      return null;
    }
    return candidate;
  } catch {
    return null;
  }
}

function firstReadableLabel(values: Array<string | undefined>): string {
  for (const value of values) {
    const normalized = value
      ?.replace(/[\u200B-\u200D\uFEFF]/g, "")
      .replace(/\s+/g, " ")
      .trim();
    if (normalized) return normalized.slice(0, maxLabelLength);
  }
  return "Link";
}
