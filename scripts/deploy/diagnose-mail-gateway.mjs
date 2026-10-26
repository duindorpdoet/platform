// SendGrid sandbox validates the request without delivering an email.
for (const name of ["SENDGRID_API", "SENDGRID_FROM_EMAIL", "TEST_EMAIL_1"]) {
  if (!process.env[name]) throw new Error(`Missing diagnostic variable: ${name}`);
}
const response = await fetch("https://api.sendgrid.com/v3/mail/send", {
  method: "POST",
  headers: { Authorization: `Bearer ${process.env.SENDGRID_API}`, "Content-Type": "application/json" },
  body: JSON.stringify({
    personalizations: [{ to: [{ email: process.env.TEST_EMAIL_1 }] }],
    from: { email: process.env.SENDGRID_FROM_EMAIL, name: "De Duindorpse Poorten van Halloween" },
    reply_to: { email: process.env.SENDGRID_FROM_EMAIL },
    subject: "Transactionele mailgateway runtimecontrole",
    content: [{ type: "text/plain", value: "Geautomatiseerde runtimecontrole." }, { type: "text/html", value: "<p>Geautomatiseerde runtimecontrole.</p>" }],
    tracking_settings: { click_tracking: { enable: false, enable_text: false }, open_tracking: { enable: false } },
    mail_settings: { sandbox_mode: { enable: true } },
  }),
  signal: AbortSignal.timeout(10_000),
});
const payload = await response.json().catch(() => ({}));
const redact = value => String(value ?? "")
  .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]")
  .replace(/SG\.[A-Za-z0-9_.-]+/g, "[redacted-key]")
  .replace(/[\r\n]/g, " ").slice(0, 400);
console.log(JSON.stringify({ sandbox: true, status: response.status, errors: Array.isArray(payload.errors)
  ? payload.errors.slice(0, 5).map(error => ({ message: redact(error.message), field: redact(error.field) })) : [] }));
