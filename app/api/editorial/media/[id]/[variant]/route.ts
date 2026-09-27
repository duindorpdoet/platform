import { serverEnv } from "@/lib/config/server-env";
import { createClient } from "@/lib/supabase/server";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { editorialPrivateHeaders } from "@/lib/editorial/server";
import { verifyEditorialToken } from "@/lib/editorial/security";
import { mediaVariants } from "@/lib/editorial/media";
export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string; variant: string }> },
) {
  const { id, variant } = await params;
  const headers = {
    ...editorialPrivateHeaders,
    "X-Content-Type-Options": "nosniff",
  };
  if (!/^[a-f0-9-]{36}$/.test(id) || !Object.hasOwn(mediaVariants, variant))
    return new Response(null, { status: 404, headers });
  const privileged = createPrivilegedClient();
  if (!privileged) return new Response(null, { status: 503, headers });
  let access: { id: string; eventId: string } | null = null;
  const token = new URL(request.url).searchParams.get("mail");
  if (token && serverEnv().EDITORIAL_TOKEN_SECRET) {
    const claim = verifyEditorialToken(
      serverEnv().EDITORIAL_TOKEN_SECRET!,
      "mail-media",
      token,
    );
    if (claim?.endsWith(`:${id}`)) {
      const result = await privileged
        .schema("api")
        .rpc("worker_editorial_mail_media", {
          _version: claim.split(":")[0],
          _media: id,
        });
      access = result.error ? null : result.data;
    }
  } else {
    const client = await createClient();
    const result = await client
      ?.schema("api")
      .rpc("editorial_media_access", { _id: id });
    access = result?.error ? null : result?.data;
  }
  if (!access) return new Response(null, { status: 404, headers });
  const file = await privileged.storage
    .from("editorial-media")
    .download(`${access.eventId}/${id}/${variant}.webp`);
  if (file.error || !file.data)
    return new Response(null, { status: 404, headers });
  return new Response(await file.data.arrayBuffer(), {
    headers: { ...headers, "Content-Type": "image/webp" },
  });
}
