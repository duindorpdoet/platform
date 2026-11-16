import sanitizeHtml from "sanitize-html";
import { Parser } from "htmlparser2";

export const PARTICIPANT_UPDATE_BODY_LIMIT = 20_000;

const blockTags = new Set(["p", "div", "h2", "h3", "h4", "ul", "ol", "li", "blockquote", "figure", "figcaption", "table", "tr", "hr"]);
const lengthStyle = /^(?:0|[0-9]{1,3}(?:\.[0-9]{1,2})?(?:px|em|rem|%))$/;

function approvedUrl(value: string | undefined, image = false): string | undefined {
  if (!value || /[\u0000-\u0020\u007f]/.test(value)) return undefined;
  try {
    const url = new URL(value);
    if (url.username || url.password) return undefined;
    if (url.protocol === "https:" || (!image && ["mailto:", "tel:"].includes(url.protocol))) return url.toString();
  } catch { /* Only absolute, explicit URLs are accepted. */ }
  return undefined;
}

function textAlternative(html: string): string {
  let text = "";
  const links: (string | undefined)[] = [];
  const breakLine = () => { if (text && !text.endsWith("\n")) text += "\n"; };
  const parser = new Parser({
    onopentag(tag, attributes) {
      if (blockTags.has(tag)) breakLine();
      if (tag === "li") text += "• ";
      if (tag === "br") text += "\n";
      if (tag === "td" || tag === "th") { if (text && !/[\n\t]$/.test(text)) text += "\t"; }
      if (tag === "a") links.push(attributes.href);
      if (tag === "img") text += `[Afbeelding${attributes.alt ? `: ${attributes.alt}` : ""}]${attributes.src ? ` (${attributes.src})` : ""}`;
    },
    ontext(value) { text += value; },
    onclosetag(tag) {
      if (tag === "a") { const href = links.pop(); if (href) text += ` (${href})`; }
      if (blockTags.has(tag)) breakLine();
    },
  });
  parser.end(html);
  return text.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
}

/** The only HTML rendering boundary for organization Updates, in browser and mail. */
export function renderParticipantUpdate(body: string): { html: string; text: string } {
  // PostgreSQL char_length counts Unicode code points, including astral characters.
  if (Array.from(body).length > PARTICIPANT_UPDATE_BODY_LIMIT) throw new RangeError("Bericht is langer dan 20.000 tekens.");
  // Match the browser's HTML bogus-comment boundary before parsing. This is
  // the upstream GHSA-2rjc-9xvg-45j7 normalization; XML/SVG are never allowed.
  const source = body.replaceAll("<![CDATA[", "<!&#91;CDATA[");
  const html = sanitizeHtml(source, {
    allowedTags: ["p", "br", "div", "span", "strong", "b", "em", "i", "u", "s", "small", "h2", "h3", "h4", "ul", "ol", "li", "blockquote", "a", "img", "hr", "figure", "figcaption", "table", "thead", "tbody", "tfoot", "tr", "td", "th"],
    allowedAttributes: {
      "*": ["style"],
      a: ["href", "title", "target", "rel", "referrerpolicy"],
      img: ["src", "alt", "title", "width", "height", "referrerpolicy"],
      td: ["colspan", "rowspan"],
      th: ["colspan", "rowspan", "scope"],
    },
    allowedStyles: {
      "*": {
        "text-align": [/^(left|right|center|justify)$/],
        "font-weight": [/^(normal|bold|[1-9]00)$/],
        "font-style": [/^(normal|italic)$/],
        "text-decoration": [/^(none|underline|line-through)$/],
        "font-size": [/^(?:1[0-9]|[2-4][0-9])px$/, /^(?:0\.[8-9]|[1-2](?:\.[0-9])?)rem$/],
        "color": [/^#[0-9a-f]{3}(?:[0-9a-f]{3})?$/i],
        "background-color": [/^#[0-9a-f]{3}(?:[0-9a-f]{3})?$/i],
        "margin-top": [lengthStyle], "margin-bottom": [lengthStyle],
        "max-width": [/^100%$/], "height": [/^auto$/], "display": [/^block$/],
      },
    },
    allowedSchemes: ["https", "mailto", "tel"],
    allowedSchemesByTag: { img: ["https"] },
    allowProtocolRelative: false,
    nonTextTags: ["script", "style", "head", "textarea", "xmp", "option", "noscript", "template", "iframe", "svg", "math"],
    transformTags: {
      a: (tagName, attributes) => {
        const href = approvedUrl(attributes.href);
        return { tagName, attribs: { ...(href ? { href } : {}), ...(attributes.title ? { title: attributes.title } : {}), target: "_blank", rel: "noopener noreferrer", referrerpolicy: "no-referrer" } };
      },
      img: (tagName, attributes) => {
        const src = approvedUrl(attributes.src, true);
        return { tagName, attribs: {
          ...(src ? { src } : {}), alt: attributes.alt || "Afbeelding bij dit bericht",
          ...(attributes.title ? { title: attributes.title } : {}),
          ...(/^[1-9][0-9]{0,3}$/.test(attributes.width || "") ? { width: attributes.width } : {}),
          style: "max-width:100%;height:auto;display:block", referrerpolicy: "no-referrer",
        } };
      },
    },
    exclusiveFilter: (frame) => frame.tag === "img" && !frame.attribs.src,
    textFilter: (text) => text.replace(/\r\n|\r|\n/g, "<br />"),
  });
  return { html, text: textAlternative(html) };
}
