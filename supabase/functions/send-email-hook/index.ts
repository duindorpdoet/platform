import { Webhook } from "npm:standardwebhooks@1.1.1";
import { handleMail } from "./handler.ts";
import { serviceRpc } from "./store.ts";
Deno.serve((request) => {
  const env = (name: string) => Deno.env.get(name);
  return handleMail(request, {
    env,
    rpc: serviceRpc(env("SUPABASE_URL") ?? "", env("SUPABASE_SERVICE_ROLE_KEY") ?? "", AbortSignal.timeout(3900)),
    verify: (body, headers) => new Webhook((env("SEND_EMAIL_HOOK_SECRET") ?? "").replace(/^v1,whsec_/, "")).verify(body, Object.fromEntries(headers), { jsonParse: true }),
  });
});
