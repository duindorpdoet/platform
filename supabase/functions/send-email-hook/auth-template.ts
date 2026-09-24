export type AuthMailTemplate = "auth_otp" | "auth_email_change" | "auth_email_change_new";

type AuthMailOptions = {
  template: AuthMailTemplate;
  token: string;
  siteUrl: string;
  supportEmail: string;
  expiresMinutes?: number;
};

const copy: Record<AuthMailTemplate, { subject: string; preheader: string; eyebrow: string; title: string; body: string; footer: string }> = {
  auth_otp: {
    subject: "Je code voor De Duindorpse Poorten",
    preheader: "Je code voor toegang tot je persoonlijke omgeving.",
    eyebrow: "Een veilige toegang",
    title: "De poort gaat voor je open.",
    body: "Vul de code hieronder in op de pagina waar je hem aanvroeg. Deel deze code met niemand.",
    footer: "Je ontvangt deze e-mail vanwege een verificatie- of inlogverzoek.",
  },
  auth_email_change: {
    subject: "Bevestig de wijziging van je e-mailadres",
    preheader: "Gebruik deze code om de wijziging op je huidige adres goed te keuren.",
    eyebrow: "Beveiliging van je account",
    title: "Controle op je huidige adres.",
    body: "Er is gevraagd om het e-mailadres van je account te wijzigen. Gebruik deze code als jij de wijziging hebt aangevraagd. Was jij dit niet? Deel de code niet en neem contact op met de organisatie.",
    footer: "Je ontvangt deze e-mail op je huidige adres vanwege een aangevraagde e-mailwijziging.",
  },
  auth_email_change_new: {
    subject: "Bevestig je nieuwe e-mailadres",
    preheader: "Gebruik deze code om je nieuwe e-mailadres te bevestigen.",
    eyebrow: "Beveiliging van je account",
    title: "Controle op je nieuwe adres.",
    body: "Gebruik onderstaande code om te bevestigen dat je toegang hebt tot dit nieuwe e-mailadres. Heb je geen wijziging aangevraagd? Deel de code niet en neem contact op met de organisatie.",
    footer: "Je ontvangt deze e-mail op het nieuwe adres vanwege een aangevraagde e-mailwijziging.",
  },
};

const escapeHtml = (value: string) => value.replace(/[&<>"']/g, (character) => ({
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
})[character]!);

function cleanHttpsOrigin(value: string) {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new TypeError("Invalid Auth site URL");
  }
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
    throw new TypeError("Auth site URL must be a clean HTTPS URL");
  }
  return url.origin;
}

export function renderAuthMail({ template, token, siteUrl, supportEmail, expiresMinutes = 10 }: AuthMailOptions) {
  if (!/^[A-Za-z0-9]{4,12}$/.test(token)) throw new TypeError("Invalid Auth code");
  if (!Number.isInteger(expiresMinutes) || expiresMinutes < 1 || expiresMinutes > 60) throw new TypeError("Invalid Auth code expiry");
  if (!/^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(supportEmail)) throw new TypeError("Invalid support email");
  const site = cleanHttpsOrigin(siteUrl);
  const selected = copy[template];
  const expiresText = `De code verloopt over ${expiresMinutes} minuten.`;
  if (selected.subject.includes(token) || selected.preheader.includes(token)) throw new TypeError("Auth code leaked into mail metadata");
  const logoUrl = `${site}/images/logo.webp`;
  const contactUrl = `${site}/contact`;
  const privacyUrl = `${site}/privacy`;
  const html = `<!doctype html><html lang="nl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><title>${escapeHtml(selected.subject)}</title><style>html,body{margin:0!important;padding:0!important;background:#060b13}table{border-spacing:0}img{border:0}@media(max-width:640px){.outer{padding:14px 10px!important}.shell{width:100%!important}.body{padding:30px 23px!important}.logo{width:270px!important}.headline{font-size:34px!important;line-height:41px!important}}</style></head><body bgcolor="#060b13" style="margin:0;background:#060b13;color:#f0e9de;"><div style="display:none;font-size:1px;color:#060b13;line-height:1px;max-height:0;opacity:0;overflow:hidden;">${escapeHtml(selected.preheader)}&nbsp;&zwnj;&nbsp;&zwnj;</div><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr><td class="outer" align="center" style="padding:32px 18px;"><table class="shell" role="presentation" width="640" cellpadding="0" cellspacing="0" border="0" bgcolor="#0b1420" style="width:640px;max-width:100%;background:#0b1420;border:1px solid #293443;border-radius:6px;overflow:hidden;"><tr><td height="3" bgcolor="#e3b68e" style="height:3px;font-size:1px;line-height:3px;"></td></tr><tr><td align="center" style="padding:30px 28px 27px;"><a href="${site}/"><img class="logo" src="${logoUrl}" width="320" height="135" alt="De Duindorpse Poorten van Halloween" style="display:block;width:320px;max-width:100%;height:auto;margin:0 auto;"></a><p style="margin:20px 0 0;color:#e3b68e;font:10px/18px Arial,sans-serif;letter-spacing:3px;text-transform:uppercase;">Een wijk. Duizend verhalen.</p></td></tr><tr><td class="body" style="padding:38px 42px 37px;"><p style="margin:0 0 16px;color:#e3b68e;font:700 10px/18px Arial,sans-serif;letter-spacing:2.8px;text-transform:uppercase;">${escapeHtml(selected.eyebrow)}</p><h1 class="headline" style="margin:0 0 20px;color:#f0e9de;font:400 36px/43px Georgia,serif;">${escapeHtml(selected.title)}</h1><p style="margin:0 0 16px;color:#f0e9de;font:16px/27px Arial,sans-serif;">${escapeHtml(selected.body)}</p><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#111e2d" style="margin:24px 0;border:1px solid #78624f;border-radius:6px;"><tr><td align="center" style="padding:26px 18px;"><p style="margin:0 0 15px;color:#e3b68e;font:11px/18px Arial,sans-serif;letter-spacing:2.5px;text-transform:uppercase;">Je eenmalige code</p><p style="margin:0 0 16px;color:#f0e9de;font:600 36px/46px 'Courier New',monospace;letter-spacing:7px;word-break:break-all;">${escapeHtml(token)}</p><p style="margin:0;color:#b8b7b8;font:13px/21px Arial,sans-serif;">${expiresText}</p></td></tr></table><div style="border-top:1px solid #293443;margin-top:30px;padding-top:25px;"><p style="margin:0 0 9px;color:#f0e9de;font:15px/25px Arial,sans-serif;">Tot in de wijk,</p><p style="margin:0;color:#e3b68e;font:400 21px/28px Georgia,serif;">Team Duindorpse Poorten</p></div></td></tr><tr><td bgcolor="#111e2d" style="padding:26px 42px;border-top:1px solid #293443;"><p style="margin:0;color:#b8b7b8;font:13px/22px Arial,sans-serif;">Een vraag? <a href="mailto:${escapeHtml(supportEmail)}" style="color:#e3b68e;">${escapeHtml(supportEmail)}</a></p></td></tr></table><table role="presentation" width="640" cellpadding="0" cellspacing="0" border="0" style="max-width:640px;"><tr><td align="center" style="padding:25px 20px;color:#a5aab3;font:12px/21px Arial,sans-serif;"><p style="margin:0 0 12px;">${escapeHtml(selected.footer)}</p><p style="margin:0;"><a href="${contactUrl}" style="color:#c5b8a9;">Contact</a>&nbsp; · &nbsp;<a href="${privacyUrl}" style="color:#c5b8a9;">Privacy</a></p></td></tr></table></td></tr></table></body></html>`;
  const text = [
    "De Duindorpse Poorten van Halloween",
    "",
    selected.title,
    "",
    selected.body,
    "",
    `Je eenmalige code: ${token}`,
    expiresText,
    "",
    "Tot in de wijk,",
    "Team Duindorpse Poorten",
    "",
    `Vragen? ${supportEmail}`,
    selected.footer,
    `Contact: ${contactUrl}`,
    `Privacy: ${privacyUrl}`,
  ].join("\n") + "\n";
  return { subject: selected.subject, preheader: selected.preheader, html, text };
}
