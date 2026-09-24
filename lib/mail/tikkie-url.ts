import { InvalidMailTemplateError } from "./premium-template";

/** A legacy mail without a link keeps its dashboard action; malformed links fail closed. */
export function validatedTikkieUrl(value: unknown): string | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string") throw new InvalidMailTemplateError("Invalid Tikkie URL");
  const candidate = value.trim();
  // Inspect the original authority as URL parsing normalizes away an explicit :443.
  const authority = /^https:\/\/([^/?#]+)(?:[/?#]|$)/i.exec(candidate)?.[1];
  if (!authority || !/^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)*tikkie\.me$/i.test(authority)
    || /[\s\\\u0000-\u001f\u007f]/.test(candidate)) {
    throw new InvalidMailTemplateError("Unapproved Tikkie URL");
  }
  let url: URL;
  try { url = new URL(candidate); }
  catch { throw new InvalidMailTemplateError("Invalid Tikkie URL"); }
  if (url.protocol !== "https:" || url.username || url.password || url.port
    || !(url.hostname === "tikkie.me" || url.hostname.endsWith(".tikkie.me"))) {
    throw new InvalidMailTemplateError("Unapproved Tikkie URL");
  }
  return url.toString();
}
