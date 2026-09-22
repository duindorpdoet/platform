const required = ["SENDGRID_API", "TEST_EMAIL_1", "TEST_EMAIL_2"];
for (const name of required) {
  if (!process.env[name]) throw new Error(`Missing required mail diagnostic variable: ${name}`);
}

const baseUrl = process.env.SENDGRID_API_BASE_URL ?? "https://api.sendgrid.com/v3";
const redact = (value) => String(value ?? "")
  .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]")
  .replace(/(?:bearer|token|secret|key)[=: ]+[^\s,;]+/gi, "$1=[redacted]")
  .replace(/[\r\n]/g, " ")
  .slice(0, 500);

for (const recipient of [...new Set([process.env.TEST_EMAIL_1, process.env.TEST_EMAIL_2].map((value) => value.toLowerCase()))]) {
  const query = encodeURIComponent(`to_email="${recipient}"`);
  const response = await fetch(`${baseUrl}/messages?limit=10&query=${query}`, {
    headers: { Authorization: `Bearer ${process.env.SENDGRID_API}` },
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) {
    const body = redact(await response.text());
    console.log(`SendGrid activity diagnostic rejected query: HTTP ${response.status}${body ? `: ${body}` : ""}`);
    continue;
  }
  const messages = (await response.json())?.messages ?? [];
  const recent = messages.filter((message) => {
    const timestamp = Date.parse(message.last_event_time ?? message.last_event_time_stamp ?? "");
    return Number.isNaN(timestamp) || timestamp >= Date.now() - 24 * 60 * 60 * 1000;
  });
  console.log(`SendGrid activity diagnostic: recipient recent activity ${recent.length}/${messages.length} message(s).`);
}
