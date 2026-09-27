import { NextResponse } from "next/server";
import { serverEnv } from "@/lib/config/server-env";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { verifyEditorialToken } from "@/lib/editorial/security";
import { editorialPrivateHeaders } from "@/lib/editorial/server";
export async function POST(request: Request) {
  const env = serverEnv();
  const token = new URL(request.url).searchParams.get("token");
  if (!token || !env.EDITORIAL_TOKEN_SECRET)
    return new Response("Deze afmeldlink is niet geldig.", {
      status: 400,
      headers: editorialPrivateHeaders,
    });
  const recipient = verifyEditorialToken(
    env.EDITORIAL_TOKEN_SECRET,
    "unsubscribe",
    token,
  );
  if (!recipient || !/^[a-f0-9-]{36}$/.test(recipient))
    return new Response("Deze afmeldlink is niet geldig.", {
      status: 400,
      headers: editorialPrivateHeaders,
    });
  const client = createPrivilegedClient();
  if (!client)
    return new Response("Probeer het later opnieuw.", {
      status: 503,
      headers: editorialPrivateHeaders,
    });
  const { error } = await client
    .schema("api")
    .rpc("worker_newsletter_unsubscribe", { _recipient: recipient });
  if (error)
    return new Response("Probeer het later opnieuw.", {
      status: 503,
      headers: editorialPrivateHeaders,
    });
  if (new URL(request.url).searchParams.get("return") === "page")
    return NextResponse.redirect(
      new URL("/nachtpost/afmelden?klaar=1", env.APP_URL),
      { status: 303, headers: editorialPrivateHeaders },
    );
  return new Response(null, { status: 204, headers: editorialPrivateHeaders });
}
