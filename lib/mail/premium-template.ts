export type MailKind = "otp" | "confirmation" | "payment" | "reminder" | "route" | "group" | "host" | "sponsor" | "admin" | "generic";

export type MailDetail = { label: string; value: string };
export type MailAction = { label: string; url: string };

export type PremiumMailContent = {
  kind: MailKind;
  subject: string;
  preheader: string;
  eyebrow: string;
  title: string;
  paragraphs: string[];
  hero?: boolean;
  details?: MailDetail[];
  notice?: { title: string; text: string };
  primaryAction?: MailAction;
  footerReason: string;
  code?: { value: string; expiresText: string };
  reference?: string;
};

export type PremiumMailBrand = {
  name: string;
  supportEmail: string;
  homeUrl: string;
  contactUrl: string;
  privacyUrl: string;
  logoUrl: string;
  heroUrl: string;
  allowedLinkHosts: string[];
  allowedImageHosts: string[];
};

export class InvalidMailTemplateError extends Error {
  readonly code = "INVALID_TEMPLATE_DATA";

  constructor(message: string) {
    super(message);
    this.name = "InvalidMailTemplateError";
  }
}

const COLORS = Object.freeze({
  background: "#060b13",
  panel: "#0b1420",
  inset: "#111e2d",
  text: "#f0e9de",
  muted: "#b8b7b8",
  gold: "#e3b68e",
  button: "#efae79",
  line: "#293443",
});

const ALLOWED_KINDS = new Set<MailKind>(["otp", "confirmation", "payment", "reminder", "route", "group", "host", "sponsor", "admin", "generic"]);

const escapeHtml = (value: unknown) => String(value ?? "").replace(/[&<>"']/g, (character) => ({
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
})[character]!);

function required(value: unknown, field: string, max = 6_000): asserts value is string {
  if (typeof value !== "string" || !value.trim() || value.length > max) {
    throw new InvalidMailTemplateError(`Invalid ${field}`);
  }
}

function safeUrl(value: string, hosts: string[], field: string) {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new InvalidMailTemplateError(`Invalid ${field}`);
  }
  if (url.protocol !== "https:" || url.username || url.password || (url.port && url.port !== "443") || !hosts.includes(url.hostname)) {
    throw new InvalidMailTemplateError(`Unapproved ${field}`);
  }
}

function validateContent(content: PremiumMailContent, brand: PremiumMailBrand) {
  if (!ALLOWED_KINDS.has(content.kind)) throw new InvalidMailTemplateError("Invalid email kind");
  for (const [field, value] of Object.entries({
    subject: content.subject,
    preheader: content.preheader,
    eyebrow: content.eyebrow,
    title: content.title,
    footerReason: content.footerReason,
  })) required(value, field, field === "subject" ? 200 : 1_000);
  if (/\r|\n/.test(content.subject)) throw new InvalidMailTemplateError("Subject must be one line");
  if (!Array.isArray(content.paragraphs) || content.paragraphs.length === 0 || content.paragraphs.length > 30) {
    throw new InvalidMailTemplateError("Invalid paragraphs");
  }
  content.paragraphs.forEach((item, index) => required(item, `paragraphs[${index}]`));
  content.details?.forEach((detail) => {
    required(detail.label, "detail label", 120);
    required(detail.value, "detail value", 1_200);
  });
  if (content.notice) {
    required(content.notice.title, "notice title", 180);
    required(content.notice.text, "notice text", 3_000);
  }
  if (content.code) {
    required(content.code.value, "code value", 12);
    if (!/^[A-Za-z0-9]{4,12}$/.test(content.code.value)) throw new InvalidMailTemplateError("Code must contain 4–12 letters or digits");
    required(content.code.expiresText, "code expiry", 300);
    if (content.subject.includes(content.code.value) || content.preheader.includes(content.code.value)) {
      throw new InvalidMailTemplateError("Do not put a login code in subject or preheader");
    }
  }
  if (content.kind === "otp" && !content.code) throw new InvalidMailTemplateError("OTP email requires a code");
  if (content.kind !== "otp" && content.code) throw new InvalidMailTemplateError("Code is reserved for OTP email");

  required(brand.name, "brand name", 150);
  required(brand.supportEmail, "support email", 320);
  if (!/^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(brand.supportEmail)) throw new InvalidMailTemplateError("Invalid support email");
  if (!brand.allowedLinkHosts.length || !brand.allowedImageHosts.length) throw new InvalidMailTemplateError("URL allowlists are required");
  safeUrl(brand.homeUrl, brand.allowedLinkHosts, "home URL");
  safeUrl(brand.contactUrl, brand.allowedLinkHosts, "contact URL");
  safeUrl(brand.privacyUrl, brand.allowedLinkHosts, "privacy URL");
  safeUrl(brand.logoUrl, brand.allowedImageHosts, "logo URL");
  if (content.hero && content.kind !== "otp") safeUrl(brand.heroUrl, brand.allowedImageHosts, "hero URL");
  if (content.primaryAction) {
    required(content.primaryAction.label, "action label", 60);
    safeUrl(content.primaryAction.url, brand.allowedLinkHosts, "action URL");
  }
}

const table = (content: string, attributes = "") => {
  const styled = attributes.includes('style="')
    ? attributes.replace('style="', 'style="width:100%;')
    : `style="width:100%;" ${attributes}`;
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" ${/\bwidth=/.test(attributes) ? "" : 'width="100%"'} ${styled}>${content}</table>`;
};
const row = (content: string, style = "", attributes = "") => `<tr><td ${attributes} style="${style}">${content}</td></tr>`;
const paragraph = (value: string) => `<p style="margin:0 0 16px;color:${COLORS.text};font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:27px;mso-line-height-rule:at-least;">${escapeHtml(value)}</p>`;

function detailsBlock(details: MailDetail[] | undefined) {
  if (!details?.length) return "";
  return table(details.map((detail, index) => `<tr><td width="40%" valign="top" style="padding:14px 18px;color:${COLORS.muted};font:13px/21px Arial,Helvetica,sans-serif;${index ? `border-top:1px solid ${COLORS.line};` : ""}">${escapeHtml(detail.label)}</td><td valign="top" style="padding:14px 18px;color:${COLORS.text};font:600 14px/21px Arial,Helvetica,sans-serif;word-wrap:break-word;${index ? `border-top:1px solid ${COLORS.line};` : ""}">${escapeHtml(detail.value)}</td></tr>`).join(""), `bgcolor="${COLORS.inset}" style="table-layout:fixed;background-color:${COLORS.inset};border:1px solid ${COLORS.line};border-radius:6px;margin:24px 0;"`);
}

function actionBlock(action: MailAction | undefined) {
  if (!action) return "";
  return `<div style="margin:28px 0 14px;">${table(row(`<a href="${escapeHtml(action.url)}" target="_blank" style="display:block;padding:17px 20px;color:#20160e;text-decoration:none;text-align:center;font:700 15px/22px Arial,Helvetica,sans-serif;border-radius:4px;">${escapeHtml(action.label)} <span aria-hidden="true">&nbsp; &rarr;</span></a>`, `background-color:${COLORS.button};background-image:linear-gradient(115deg,#e39059,#f5bd88);border:1px solid #f5c49d;border-radius:4px;`, `bgcolor="${COLORS.button}"`), 'class="primary-button" style="width:300px;max-width:100%;"')}</div>`;
}

export function renderPremiumEmail(content: PremiumMailContent, brand: PremiumMailBrand) {
  validateContent(content, brand);
  const otp = content.kind === "otp";
  const codeBlock = content.code
    ? table(row(`<p style="margin:0 0 15px;font:11px/18px Arial,Helvetica,sans-serif;letter-spacing:2.5px;text-transform:uppercase;color:${COLORS.gold};">Je eenmalige code</p><p style="margin:0 0 16px;font:600 36px/46px 'Courier New',monospace;letter-spacing:7px;color:${COLORS.text};word-break:break-all;">${escapeHtml(content.code.value)}</p><p style="margin:0;font:13px/21px Arial,Helvetica,sans-serif;color:${COLORS.muted};">${escapeHtml(content.code.expiresText)}</p>`, "padding:26px 18px;text-align:center;"), `bgcolor="${COLORS.inset}" style="background:${COLORS.inset};border:1px solid #78624f;border-radius:6px;margin:24px 0;"`)
    : "";
  const notice = content.notice
    ? table(row(`<p style="margin:0 0 7px;font:700 14px/22px Arial,Helvetica,sans-serif;color:${COLORS.gold};">${escapeHtml(content.notice.title)}</p><p style="margin:0;font:14px/23px Arial,Helvetica,sans-serif;color:${COLORS.text};">${escapeHtml(content.notice.text)}</p>`, "padding:18px 20px;border-left:2px solid #e3b68e;"), 'bgcolor="#15202c" style="background:#15202c;margin:24px 0;"')
    : "";
  const contentHtml = `<p style="margin:0 0 16px;font:700 10px/18px Arial,Helvetica,sans-serif;letter-spacing:2.8px;text-transform:uppercase;color:${COLORS.gold};">${escapeHtml(content.eyebrow)}</p>
<h1 class="headline" style="margin:0 0 20px;font:400 ${otp ? 36 : 42}px/${otp ? 43 : 49}px Georgia,'Times New Roman',serif;letter-spacing:-1.2px;color:${COLORS.text};">${escapeHtml(content.title)}</h1>
${content.paragraphs.map(paragraph).join("")}${codeBlock}${detailsBlock(content.details)}${notice}${actionBlock(content.primaryAction)}
${content.primaryAction ? `<p style="margin:15px 0 0;font:11px/18px Arial,Helvetica,sans-serif;color:${COLORS.muted};word-break:break-all;overflow-wrap:anywhere;">Werkt de knop niet? Open deze link:<br><a href="${escapeHtml(content.primaryAction.url)}" style="color:${COLORS.muted};text-decoration:underline;">${escapeHtml(content.primaryAction.url)}</a></p>` : ""}
<div style="border-top:1px solid ${COLORS.line};margin:30px 0 0;padding:25px 0 0;"><p style="margin:0 0 9px;font:15px/25px Arial,Helvetica,sans-serif;color:${COLORS.text};">${otp ? "Tot in de wijk," : "Tot tussen de poorten,"}</p><p style="margin:0;font:400 21px/28px Georgia,'Times New Roman',serif;color:${COLORS.gold};">Team Duindorpse Poorten</p></div>`;

  const hero = content.hero && !otp
    ? row(`<img class="hero-image" src="${escapeHtml(brand.heroUrl)}" width="640" height="360" alt="Duindorp bij avond met warme ramen en Halloweenlichtjes." style="display:block;width:100%;max-width:640px;height:auto;color:${COLORS.text};font:14px/22px Arial,sans-serif;">`, `padding:0;background:${COLORS.inset};`)
    : "";
  const shellRows =
    row("", "height:3px;font-size:1px;line-height:3px;background:#e3b68e;", 'height="3" bgcolor="#e3b68e"')
    + row(`<a href="${escapeHtml(brand.homeUrl)}" style="text-decoration:none;"><img class="brand-logo" src="${escapeHtml(brand.logoUrl)}" width="320" height="135" alt="${escapeHtml(brand.name)}" style="display:block;width:320px;max-width:100%;height:auto;margin:0 auto;"></a><p style="margin:20px 0 0;color:${COLORS.gold};font:10px/18px Arial,Helvetica,sans-serif;letter-spacing:3px;text-transform:uppercase;">Een wijk. Duizend verhalen.</p>`, `padding:30px 28px 27px;text-align:center;background:${COLORS.panel};`)
    + hero
    + row(contentHtml, `padding:38px 42px 37px;text-align:left;background:${COLORS.panel};`, 'class="body-pad"')
    + row(`<p style="margin:0 0 11px;font:400 22px/30px Georgia,serif;color:${COLORS.text};">De mooiste magie maken we samen.</p><p style="margin:0;font:13px/22px Arial,Helvetica,sans-serif;color:${COLORS.muted};">Een vraag? <a href="mailto:${escapeHtml(brand.supportEmail)}" style="color:${COLORS.gold};">${escapeHtml(brand.supportEmail)}</a></p>`, `padding:26px 42px;background:${COLORS.inset};border-top:1px solid ${COLORS.line};`, 'class="footer-pad"');
  const shell = table(shellRows, `class="email-shell" align="center" width="640" bgcolor="${COLORS.panel}" style="width:640px;max-width:100%;background:${COLORS.panel};border:1px solid ${COLORS.line};border-radius:6px;overflow:hidden;"`);
  const footerContent = `<p style="margin:0 0 12px;font:12px/21px Arial,Helvetica,sans-serif;color:#a5aab3;">${escapeHtml(content.footerReason)}</p><p style="margin:0 0 13px;font:12px/22px Arial,Helvetica,sans-serif;"><a href="${escapeHtml(brand.homeUrl)}" style="color:#c5b8a9;">Website</a>&nbsp; · &nbsp;<a href="${escapeHtml(brand.contactUrl)}" style="color:#c5b8a9;">Contact</a>&nbsp; · &nbsp;<a href="${escapeHtml(brand.privacyUrl)}" style="color:#c5b8a9;">Privacy</a></p>${content.reference ? `<p style="margin:8px 0 0;font:10px/16px Arial;color:#a5aab3;">Referentie ${escapeHtml(content.reference)}</p>` : ""}`;
  const footer = table(row(footerContent, "padding:25px 20px;text-align:center;"), 'align="center" style="max-width:640px;"');
  const preheader = `<div style="display:none;font-size:1px;color:${COLORS.background};line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;">${escapeHtml(content.preheader)}&nbsp;&zwnj;&nbsp;&zwnj;</div>`;
  const html = `<!doctype html><html lang="nl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="x-apple-disable-message-reformatting"><meta name="format-detection" content="telephone=no,date=no,address=no,email=no"><meta name="color-scheme" content="dark"><title>${escapeHtml(content.subject)}</title><style>html,body{margin:0!important;padding:0!important;width:100%!important;background:${COLORS.background}}table,td{mso-table-lspace:0;mso-table-rspace:0}table{border-spacing:0}img{border:0;outline:none;text-decoration:none}.ExternalClass{width:100%}@media only screen and (max-width:640px){.outer-space{padding:14px 10px!important}.email-shell{width:100%!important}.body-pad{padding:30px 23px!important}.headline{font-size:34px!important;line-height:41px!important}.brand-logo{width:270px!important}.footer-pad{padding:24px 23px!important}.primary-button{width:100%!important}.hero-image{width:100%!important;height:auto!important}}</style></head><body bgcolor="${COLORS.background}" style="margin:0;padding:0;background:${COLORS.background};color:${COLORS.text};">${preheader}${table(row(`${shell}${footer}`, "padding:32px 18px;", 'class="outer-space" align="center"'))}</body></html>`;

  const text = [
    brand.name,
    "",
    content.title,
    "",
    ...content.paragraphs.flatMap((item) => [item, ""]),
    content.code ? `Je eenmalige code: ${content.code.value}\n${content.code.expiresText}` : "",
    ...(content.details ?? []).map((detail) => `${detail.label}: ${detail.value}`),
    content.notice ? `\n${content.notice.title}\n${content.notice.text}` : "",
    content.primaryAction ? `\n${content.primaryAction.label}: ${content.primaryAction.url}` : "",
    "",
    otp ? "Tot in de wijk," : "Tot tussen de poorten,",
    "Team Duindorpse Poorten",
    "",
    `Vragen? ${brand.supportEmail}`,
    content.footerReason,
    `Website: ${brand.homeUrl}`,
    `Contact: ${brand.contactUrl}`,
    `Privacy: ${brand.privacyUrl}`,
    content.reference ? `Referentie: ${content.reference}` : "",
  ].join("\n").replace(/\n{3,}/g, "\n\n").trim() + "\n";

  return { subject: content.subject, preheader: content.preheader, html, text };
}
