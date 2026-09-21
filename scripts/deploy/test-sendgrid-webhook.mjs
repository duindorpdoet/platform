for (const name of ["APP_URL", "SENDGRID_API", "SENDGRID_EVENT_WEBHOOK_ID"]) {
  if (!process.env[name]) throw new Error(`Missing required SendGrid test variable: ${name}`);
}

const baseUrl = process.env.SENDGRID_API_BASE_URL ?? "https://api.sendgrid.com/v3";
const endpoint = `${new URL(process.env.APP_URL).origin}/api/webhooks/sendgrid`;
const response = await fetch(`${baseUrl}/user/webhooks/event/test`, {
  method: "POST",
  headers: { Authorization: `Bearer ${process.env.SENDGRID_API}`, "Content-Type": "application/json" },
  body: JSON.stringify({ id: process.env.SENDGRID_EVENT_WEBHOOK_ID, url: endpoint }),
});
if (response.status !== 204) throw new Error(`SendGrid Event Webhook test was rejected (${response.status}).`);
console.log("Signed SendGrid Event Webhook test request was accepted.");
