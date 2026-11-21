import { DomUtils, parseDocument } from "htmlparser2";

// domhandler is only a transitive dependency, so derive its types here.
type ChildNode = ReturnType<typeof parseDocument>["children"][number];
type Element = Parameters<typeof DomUtils.getName>[0];

export interface SafeHtmlResult {
  /** Empty when the mail has no usable HTML or exceeds the element budget. */
  html: string;
  /** Number of remote (http/https) images removed or, with allowRemoteImages, kept. */
  remoteImageCount: number;
}

export interface SafeHtmlOptions {
  allowRemoteImages?: boolean;
}

const allowedTags = new Set([
  "a", "abbr", "b", "big", "blockquote", "br", "caption", "center", "code",
  "col", "colgroup", "dd", "div", "dl", "dt", "em", "font", "h1", "h2", "h3",
  "h4", "h5", "h6", "hr", "i", "img", "li", "ol", "p", "pre", "s", "small",
  "span", "strike", "strong", "sub", "sup", "table", "tbody", "td", "tfoot",
  "th", "thead", "tr", "u", "ul"
]);
// Dropped together with their contents; every other unknown tag is unwrapped.
const droppedTags = new Set([
  "script", "style", "iframe", "frame", "frameset", "object", "embed", "applet",
  "noscript", "template", "textarea", "select", "option", "svg", "math", "head",
  "title", "link", "meta", "base", "audio", "video", "canvas", "map", "xml"
]);
const voidTags = new Set(["br", "hr", "img", "col"]);
const globalAttrs = new Set(["title", "dir", "lang", "align", "valign"]);
const tagAttrs: Record<string, Set<string>> = {
  td: new Set(["colspan", "rowspan", "width", "height", "bgcolor"]),
  th: new Set(["colspan", "rowspan", "width", "height", "bgcolor"]),
  table: new Set(["width", "height", "bgcolor", "cellpadding", "cellspacing", "border"]),
  col: new Set(["span", "width"]),
  font: new Set(["color", "size", "face"]),
  img: new Set(["alt", "width", "height"])
};
const allowedStyleProps = new Set([
  "color", "background-color", "font-size", "font-weight", "font-style",
  "font-family", "text-align", "text-decoration", "line-height", "margin",
  "margin-top", "margin-bottom", "margin-left", "margin-right", "padding",
  "padding-top", "padding-bottom", "padding-left", "padding-right", "width",
  "height", "max-width", "vertical-align", "white-space", "letter-spacing",
  "text-transform", "border", "border-top", "border-bottom", "border-left",
  "border-right", "border-collapse", "border-radius"
]);
const safeAttrValue = /^[\w\s#%.,:/()\-+]*$/;
// width/height attrs: plain number with optional px or %; drops Infinity/NaN/huge.
const sizeAttr = /^\d{1,4}(px|%)?$/;
const maxDepth = 100;
// More elements than this means a pathological mail: return no HTML so the
// client shows the plain-text body instead of building a huge widget tree.
export const maxElements = 5000;
// colspan/rowspan above this are clamped so a table cannot claim huge grids.
const maxSpan = 50;
function clampSpan(value: string): string {
  const n = Number.parseInt(value, 10);
  return String(Number.isFinite(n) ? Math.min(Math.max(n, 1), maxSpan) : 1);
}
class BudgetExceeded extends Error {}

export function sanitizeHtml(
  source: string,
  options: SafeHtmlOptions = {}
): SafeHtmlResult {
  const state = { remoteImageCount: 0, allowRemote: options.allowRemoteImages === true, elements: 0 };
  try {
    const html = serializeNodes(parseDocument(source).children, state, 0);
    return { html, remoteImageCount: state.remoteImageCount };
  } catch (error) {
    if (error instanceof BudgetExceeded) return { html: "", remoteImageCount: 0 };
    throw error;
  }
}

interface State {
  remoteImageCount: number;
  allowRemote: boolean;
  elements: number;
}

function serializeNodes(nodes: ChildNode[], state: State, depth: number): string {
  // Silently dropping deep content would leave non-empty html; fall back to plain text instead.
  if (depth > maxDepth) throw new BudgetExceeded();
  let out = "";
  for (const node of nodes) {
    if (DomUtils.isText(node)) {
      out += escapeText(node.data);
    } else if (DomUtils.isTag(node)) {
      out += serializeElement(node, state, depth);
    }
    // comments, directives, CDATA and processing instructions are dropped.
  }
  return out;
}

function serializeElement(el: Element, state: State, depth: number): string {
  if (++state.elements > maxElements) throw new BudgetExceeded();
  const name = el.name.toLowerCase();
  if (droppedTags.has(name)) return "";
  if (name === "img") return serializeImage(el, state);
  if (name === "body") {
    // body itself is unwrapped, but its background and text color must survive
    // (children inherit the color) or the mail renders unreadable on the client.
    const style = bodyStyle(el.attribs);
    const inner = serializeNodes(el.children, state, depth + 1);
    return style ? `<div style="${escapeAttr(style)}">${inner}</div>` : inner;
  }
  if (!allowedTags.has(name)) return serializeNodes(el.children, state, depth + 1);

  const attrs = serializeAttributes(name, el.attribs);
  if (voidTags.has(name)) return `<${name}${attrs}>`;
  return `<${name}${attrs}>${serializeNodes(el.children, state, depth + 1)}</${name}>`;
}

function serializeImage(el: Element, state: State): string {
  let src = (el.attribs.src ?? "").trim();
  if (/^\/\//.test(src)) src = `https:${src}`; // protocol-relative: load over https
  const alt = el.attribs.alt ?? "";
  if (/^(?:https?:)?\/\//i.test(src)) {
    state.remoteImageCount += 1;
    if (state.allowRemote && /^https?:\/\//i.test(src)) {
      return `<img src="${escapeAttr(src)}"${serializeAttributes("img", el.attribs)}>`;
    }
  }
  // Blocked, data:, cid: and unknown sources (data: can claim a huge decoded size): keep only the alt text.
  return escapeText(alt);
}

function serializeAttributes(tag: string, attribs: Record<string, string>): string {
  let out = "";
  const tagSet = tagAttrs[tag];
  for (const [rawKey, value] of Object.entries(attribs)) {
    const key = rawKey.toLowerCase();
    if (key === "style") {
      const style = sanitizeStyle(value);
      if (style) out += ` style="${escapeAttr(style)}"`;
    } else if (key === "href" && tag === "a") {
      const href = safeHref(value);
      if (href) out += ` href="${escapeAttr(href)}"`;
    } else if (
      (globalAttrs.has(key) || tagSet?.has(key)) &&
      !(tag === "img" && key === "src") &&
      !((key === "width" || key === "height") && !sizeAttr.test(value)) &&
      value.length <= 200 &&
      (key === "title" || key === "alt" || key === "face" || safeAttrValue.test(value))
    ) {
      out += ` ${key}="${escapeAttr(key === "colspan" || key === "rowspan" ? clampSpan(value) : value)}"`;
    }
  }
  return out;
}

function bodyStyle(attribs: Record<string, string>): string {
  const pick = (attr: string | undefined): string | null => {
    const v = (attr ?? "").trim();
    return v && v.length <= 200 && safeAttrValue.test(v) ? v : null;
  };
  let bg = pick(attribs.bgcolor);
  let color = pick(attribs.text);
  for (const declaration of sanitizeStyle(attribs.style ?? "").split(";")) {
    if (declaration.startsWith("background-color:")) bg = declaration.slice("background-color:".length);
    else if (declaration.startsWith("color:")) color = declaration.slice("color:".length);
  }
  return [bg && `background-color:${bg}`, color && `color:${color}`].filter(Boolean).join(";");
}

function safeHref(value: string): string | null {
  // Drop control chars (browsers ignore them inside schemes: "java\tscript:"),
  // trim the ends, and encode inner spaces so paths/queries keep their meaning.
  // The scheme is validated on this same string, so "java script:" stays invalid.
  const candidate = value.replace(/[\u0000-\u001f\u007f-\u009f]/g, "").trim().replace(/ /g, "%20");
  if (!candidate || candidate.length > 8192) return null;
  try {
    const url = new URL(candidate);
    const scheme = url.protocol.toLowerCase();
    if (scheme !== "http:" && scheme !== "https:" && scheme !== "mailto:") return null;
    if (scheme !== "mailto:" && !url.host) return null;
    return candidate;
  } catch {
    return null;
  }
}

function sanitizeStyle(style: string): string {
  const kept: string[] = [];
  for (const declaration of style.split(";")) {
    const index = declaration.indexOf(":");
    if (index < 0) continue;
    const prop = declaration.slice(0, index).trim().toLowerCase();
    const value = declaration.slice(index + 1).trim();
    if (!allowedStyleProps.has(prop) || !value) continue;
    // No url(), expression(), escapes, comments or at-rules in any value.
    if (/url\s*\(|expression|[\\@]|\/\*|javascript|behavior|<|>|\bimage\b/i.test(value)) continue;
    kept.push(`${prop}:${value}`);
  }
  return kept.join(";");
}

function escapeText(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function escapeAttr(value: string): string {
  return escapeText(value).replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
