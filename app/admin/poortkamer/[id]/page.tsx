import { notFound, redirect } from "next/navigation";
import { getActor } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { serverEnv } from "@/lib/config/server-env";
import { Poortkamer } from "@/components/portal/poortkamer";
import type { PortalRoom } from "@/lib/domain/poortkamer";
export const dynamic = "force-dynamic";
export default async function AdminPortalRoom({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  if (!(await getActor())) redirect("/inloggen?next=/admin");
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const client = await createClient();
  if (!client) notFound();
  const eventSlug = serverEnv().EVENT_SLUG;
  const access = await client
    .schema("api")
    .rpc("admin_portal_room_snapshot", { _event_slug: eventSlug });
  if (access.error) notFound();
  const room = await client
    .schema("api")
    .rpc("portal_room_snapshot", { _event_slug: eventSlug, _portal_id: id });
  if (!room.data || room.error) notFound();
  return (
    <Poortkamer eventSlug={eventSlug} initial={room.data as PortalRoom} admin />
  );
}
