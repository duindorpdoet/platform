import { recipientAllowed } from "./policy.ts";
import { Webhook } from "npm:standardwebhooks@1.1.1";
import { deliveriesForPayload, type HookPayload } from "./payload.ts";
import { providerAccepted, sendHookDeliveries, sendTransactionalDelivery } from "./send.ts";
import { transactionalMessageForPayload } from "./transactional.ts";

Deno.serve(async (request) => {
  const hookSecret = Deno.env.get("SEND_EMAIL_HOOK_SECRET")?.replace(/^v1,whsec_/, "");
  const apiKey = Deno.env.get("SENDGRID_API_KEY") ?? Deno.env.get("SENDGRID_API");
  const from = Deno.env.get("SENDGRID_FROM_EMAIL");
  const mailMode = Deno.env.get("MAIL_MODE") ?? "disabled";
  const authMailMode = Deno.env.get("AUTH_MAIL_MODE") ?? mailMode;

  if (!hookSecret || !apiKey || !from) return new Response("not configured", { status: 503 });
  if (request.method !== "POST") return new Response("method not allowed", { status: 405 });
  if (Number(request.headers.get("content-length") ?? "0") > 128_000) return new Response("too large", { status: 413 });

  const body = await request.text();
  if (body.length > 128_000) return new Response("too large", { status: 413 });

  let verifiedPayload: unknown;
  try {
    verifiedPayload = new Webhook(hookSecret).verify(body, Object.fromEntries(request.headers), { jsonParse: true });
  } catch {
    return new Response("invalid signature", { status: 401 });
  }

  const allowlist = new Set(
    (Deno.env.get("MAIL_ALLOWED_RECIPIENTS") ?? "")
      .split(",")
      .map((email) => email.trim().toLowerCase())
      .filter(Boolean),
  );

  const transactional = transactionalMessageForPayload(verifiedPayload);
  if (transactional) {
    if (
      !recipientAllowed(mailMode, transactional.to, allowlist)
    ) {
      return new Response("recipient disabled", { status: 403 });
    }

    const sandbox = mailMode === "sandbox" || transactional.providerProbe === true;
    let providerResponse: Response;
    try {
      providerResponse = await sendTransactionalDelivery({
        email: transactional.to,
        subject: transactional.subject,
        text: transactional.text,
        html: transactional.html,
        outboxId: transactional.outboxId,
        replyTo: transactional.replyTo,
        apiKey,
        from,
        fromName: Deno.env.get("SENDGRID_FROM_NAME") ?? "De Duindorpse Poorten van Halloween",
        sandbox,
      });
    } catch {
      return new Response("provider timeout", { status: 504 });
    }

    console.log(JSON.stringify({
      event: "transactional_email_provider_response",
      status: providerResponse.status,
      sandbox,
    }));

    if (!providerAccepted(providerResponse, sandbox)) {
      return new Response("provider rejected", { status: 502 });
    }

    const headers = new Headers({ "content-type": "application/json" });
    const providerId = providerResponse.headers.get("x-message-id");
    if (providerId) headers.set("x-provider-message-id", providerId);
    return new Response(JSON.stringify({}), { status: 200, headers });
  }

  const payload = verifiedPayload as HookPayload;
  const { deliveries: emails, supported } = deliveriesForPayload(payload);
  if (!supported) return new Response("unsupported action", { status: 422 });
  if (emails.length === 0) return new Response("invalid payload", { status: 422 });

  if (
    emails.some(({ email }) => !recipientAllowed(authMailMode, email, allowlist))
  ) {
    return new Response("recipient disabled", { status: 403 });
  }

  const providerProbe = payload.email_data.email_action_type === "staging_provider_probe";
  const providerProbeId = (payload.email_data.token_hash ?? "probe").replace(/[^a-zA-Z0-9-]/g, "").slice(-12);
  const subject = providerProbe ? `Staging mailprovidercontrole ${providerProbeId}` : "Je zescijferige inlogcode";
  const sandbox = authMailMode === "sandbox";

  let responses: Response[];
  try {
    responses = await sendHookDeliveries({
      deliveries: emails,
      apiKey,
      from,
      fromName: Deno.env.get("SENDGRID_FROM_NAME") ?? "De Duindorpse Poorten van Halloween",
      subject,
      providerProbe,
      sandbox,
    });
  } catch {
    return new Response("provider timeout", { status: 504 });
  }

  console.log(JSON.stringify({
    event: "auth_email_provider_response",
    statuses: responses.map((response) => response.status),
    sandbox,
  }));

  if (responses.some((response) => !providerAccepted(response, sandbox))) {
    return new Response("provider rejected", { status: 502 });
  }

  return new Response(JSON.stringify({}), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
});
