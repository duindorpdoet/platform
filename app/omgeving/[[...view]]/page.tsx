import { redirect } from "next/navigation";
import { ParticipantShell, type ParticipantContext, type ParticipantRoleKey } from "@/components/participant/participant-shell";
import { getActor } from "@/lib/auth/session";
import { serverEnv } from "@/lib/config/server-env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

const roleBySlug: Record<string, ParticipantRoleKey> = {
  meeloper: "walker",
  meekijker: "viewer",
  huiseigenaar: "homeowner",
};

export default async function ParticipantEnvironmentPage({
  params,
  searchParams,
}: {
  params: Promise<{ view?: string[] }>;
  searchParams: Promise<{ meekijkuitnodiging?: string }>;
}) {
  const actor = await getActor();
  const segments = (await params).view ?? [];
  const rawInvite = (await searchParams).meekijkuitnodiging;
  const inviteToken = rawInvite && /^[a-f0-9]{64}$/.test(rawInvite) ? rawInvite : undefined;
  const destination = inviteToken ? `/omgeving?meekijkuitnodiging=${inviteToken}` : `/omgeving/${segments.join("/")}`;
  if (!actor) redirect(`/inloggen?next=${encodeURIComponent(destination)}`);

  const eventSlug = serverEnv().EVENT_SLUG;
  const client = await createClient();
  const { data, error } = client
    ? await client.schema("api").rpc("participant_context", { _event_slug: eventSlug })
    : { data: null, error: { message: "Supabase unavailable" } };
  if (error || !data) {
    return <div className="participant-load-error"><h1>Je omgeving is even niet bereikbaar</h1><p>Vernieuw de pagina of probeer het over een paar minuten opnieuw.</p></div>;
  }

  const context = data as ParticipantContext;
  const requestedRole = roleBySlug[segments[0] ?? ""];
  const selectedRole = context.roles.some((role) => role.key === requestedRole)
    ? requestedRole
    : context.roles[0]?.key;

  return (
    <ParticipantShell
      context={context}
      eventSlug={eventSlug}
      userId={actor.userId}
      role={selectedRole}
      section={segments[1]}
      inviteToken={inviteToken}
    />
  );
}
