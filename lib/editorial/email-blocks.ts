import { validateRichContent, type RichNode } from "./content";
export const escapeEditorialHtml = (value: unknown) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );
export function renderEmailBlocks(
  body: RichNode,
  mediaUrls: Record<string, string>,
  origin: string,
): string {
  const document = validateRichContent(body);
  const render = (node: RichNode): string => {
    const inner = (node.content ?? []).map(render).join("");
    const align = ["left", "center", "right"].includes(
      String(node.attrs?.textAlign),
    )
      ? node.attrs?.textAlign
      : "left";
    const style = `color:#f0e9de;font:16px/27px Arial,Helvetica,sans-serif;text-align:${align};margin:0 0 18px;`;
    switch (node.type) {
      case "doc":
        return inner;
      case "text":
        return (node.marks ?? []).reduce((value, mark) => {
          if (mark.type === "bold") return `<strong>${value}</strong>`;
          if (mark.type === "italic") return `<em>${value}</em>`;
          if (mark.type === "underline") return `<u>${value}</u>`;
          const href = mark.attrs.href.startsWith("/")
            ? new URL(mark.attrs.href, origin).href
            : mark.attrs.href;
          return `<a href="${escapeEditorialHtml(href)}" style="color:#efbd8c;text-decoration:underline;">${value}</a>`;
        }, escapeEditorialHtml(node.text));
      case "paragraph":
        return `<p style="${style}">${inner || "&nbsp;"}</p>`;
      case "heading":
        return `<h${node.attrs?.level} style="${style}font-family:Georgia,serif;font-size:${node.attrs?.level === 2 ? 28 : 23}px;line-height:1.3;">${inner}</h${node.attrs?.level}>`;
      case "bulletList":
        return `<ul style="${style}padding-left:24px;">${inner}</ul>`;
      case "orderedList":
        return `<ol start="${Number(node.attrs?.start ?? 1)}" style="${style}padding-left:24px;">${inner}</ol>`;
      case "listItem":
        return `<li style="${style}">${inner}</li>`;
      case "blockquote":
      case "callout":
        return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:22px 0;background:#172433;border-left:3px solid #e3b68e;"><tr><td style="padding:20px;${style}">${inner}</td></tr></table>`;
      case "horizontalRule":
        return '<hr style="border:0;border-top:1px solid #384658;margin:26px 0;">';
      case "hardBreak":
        return "<br>";
      case "image": {
        const url = mediaUrls[String(node.attrs?.mediaId)];
        if (
          !url ||
          new URL(url, origin).protocol !== "https:" ||
          !!new URL(url, origin).username ||
          !!new URL(url, origin).password ||
          new URL(url, origin).origin !== new URL(origin).origin
        )
          throw new Error("Unapproved email image");
        return `<table role="presentation" width="${node.attrs?.width}%" align="center" style="margin:24px auto;max-width:100%;"><tr><td><img src="${escapeEditorialHtml(url)}" alt="${escapeEditorialHtml(node.attrs?.alt)}" width="${Math.round((556 * Number(node.attrs?.width)) / 100)}" style="display:block;width:100%;height:auto;border:0;">${node.attrs?.caption ? `<p style="color:#c6beb3;font:13px/20px Arial,sans-serif;margin:10px 0;">${escapeEditorialHtml(node.attrs.caption)}</p>` : ""}</td></tr></table>`;
      }
      default:
        throw new Error("Unsupported editorial node");
    }
  };
  return render(document);
}
