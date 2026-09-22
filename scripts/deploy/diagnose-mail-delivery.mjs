// Read-only diagnostics after failed mailbox acceptance. Never log credentials,
// message contents, OTPs or recipient addresses.
const headers = { Authorization: `Bearer ${process.env.SENDGRID_API}` };
for (const [index, recipient] of [process.env.TEST_EMAIL_1, process.env.TEST_EMAIL_2].entries()) {
  for (const kind of ["blocks", "bounces", "invalid_emails"]) {
    try {
      const response = await fetch(`https://api.sendgrid.com/v3/suppression/${kind}/${encodeURIComponent(recipient)}`, { headers, signal: AbortSignal.timeout(10_000) });
      if (!response.ok) { console.log(`Recipient ${index + 1} ${kind}: HTTP ${response.status}`); continue; }
      const rows = await response.json();
      console.log(`Recipient ${index + 1} ${kind}: ${JSON.stringify(rows.map((row) => ({
        created: row.created,
        reason: String(row.reason ?? "").replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]").replace(/[\r\n]/g, " ").slice(0, 600),
      })))}`);
    } catch { console.log(`Recipient ${index + 1} ${kind}: diagnostic request unavailable`); }
  }
}

for (const [index, recipient] of [process.env.TEST_EMAIL_1, process.env.TEST_EMAIL_2].entries()) {
  const since = new Date(Date.now() - 15 * 60_000).toISOString().replace("T", " ").slice(0, 19);
  const query = `last_event_time >= TIMESTAMP "${since}" AND to_email="${recipient}"`;
  try {
    const response = await fetch(`https://api.sendgrid.com/v3/messages?limit=10&query=${encodeURIComponent(query)}`, { headers, signal: AbortSignal.timeout(45_000) });
    console.log(`Recipient ${index + 1} recent activity: HTTP ${response.status}`);
    if (response.ok) {
      const body = await response.json();
      for (const message of body.messages ?? []) {
        console.log(JSON.stringify({ recipient: index + 1, status: message.status, last_event_time: message.last_event_time, is_otp: message.subject === "Je zescijferige inlogcode", is_probe: message.subject?.startsWith("Staging mailprovidercontrole") }));
      }
    }
  } catch { console.log(`Recipient ${index + 1} recent activity unavailable after bounded request`); }
}
