import Link from "next/link";
import { redirect } from "next/navigation";
import { Users } from "lucide-react";
import { GroupExperience } from "@/components/group/group-experience";
import { SupportWidget } from "@/components/support/support-widget";
import { SignOutButton } from "@/components/auth/account-actions";
import { getActor } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";
import { serverEnv } from "@/lib/config/server-env";

export const dynamic = "force-dynamic";

export default async function MyGroupPage() {
  const actor = await getActor();
  if (!actor) redirect("/inloggen?next=/mijn-groep");
  const client = await createClient();
  const eventSlug = serverEnv().EVENT_SLUG;
  const { data } = client ? await client.schema("api").rpc("my_context", { _event_slug: eventSlug }) : { data: null };
  const groupIds = ((data as { groupIds?: string[] } | null)?.groupIds ?? []);
  return <><div className="page wrap">{groupIds[0] ? <GroupExperience groupId={groupIds[0]} userId={actor.userId} /> : <div className="panel empty-state"><Users size={36} /><h1>Jullie groep komt eraan</h1><p>We maken de groepen zorgvuldig. Zodra jullie starttijd en eerste halte klaarstaan, vind je die hier. Tot die tijd kun je de werelden alvast ontdekken.</p><div className="actions"><Link className="btn" href="/werelden">Ontdek de werelden</Link><Link className="btn outline" href="/mijn-inschrijving">Bekijk jullie inschrijving</Link><SignOutButton /></div></div>}</div><SupportWidget eventSlug={eventSlug} role={groupIds[0] ? "walker" : "user"} groupId={groupIds[0]} /></>;
}
