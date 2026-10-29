import { expect } from "@playwright/test";
import type { SupabaseClient } from "@supabase/supabase-js";
import { readFileSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { requireLocalTogetherDatabase, sql } from "../../../scripts/acceptance/together-fixtures.mjs";
import { proposeJointRoutes, type JointRouteInput } from "../../../lib/domain/joint-route-planner";

/** Expand the actual shared SQL fixture, including nested relative includes. */
export function fixtureSql(path: string): string {
  const file = realpathSync(path);
  return readFileSync(file, "utf8").replace(/^\\ir\s+(.+)$/gm, (_, relative: string) => fixtureSql(resolve(dirname(file), relative.trim())));
}

/** Existing single-group UI scenarios retain every seeded family. Give only
 * other unassigned groups explicit, separately published synthetic appointments
 * before asking the real joint planner to validate their shared calendar. */
export function prepareOtherRouteAppointments(eventSlug: string, excludedGroupId: string) {
  requireLocalTogetherDatabase();
  if (!/^[a-z0-9-]+$/.test(eventSlug) || !/^[a-f0-9-]{36}$/.test(excludedGroupId)) throw new Error("INVALID_SYNTHETIC_ROUTE_CONTEXT");
  sql(`do $fixture$
  declare eid uuid; g record; point uuid; schedule uuid; slot_time timestamptz; base_time timestamptz; transfer integer; spacing integer; n integer:=0;
  begin
   perform set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
   select id into eid from app_private.events where slug='${eventSlug}';
   select finale_planning_transfer_seconds into transfer from app_private.event_route_settings where event_id=eid;
   select greatest(300,ceil(greatest(w.visit_seconds+w.buffer_seconds,w.headway_seconds)/300.0)::integer*300) into spacing
    from app_private.event_route_settings settings cross join lateral app_private.portal_effective_windows(settings.final_portal_id)w
    where settings.event_id=eid order by w.opens_at limit 1;
   if spacing is null then raise exception 'SYNTHETIC_FINALE_WINDOW_REQUIRED';end if;
   select min(value::timestamptz) into base_time from jsonb_array_elements_text(app_private.exact_preference_options(eid)->'allowedStartTimes');
   for g in select groups.* from app_private.walking_groups groups
    where groups.event_id=eid and groups.id<>'${excludedGroupId}' and groups.current_schedule_revision_id is null and groups.retired_at is null
     and exists(select 1 from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id
      where a.group_id=groups.id and a.superseded_at is null and c.participation_status='active') order by groups.id
   loop
    n:=n+1;slot_time:=base_time+make_interval(mins=>n*10);
    point:=(api.admin_startregie_start_point_save('${eventSlug}',null,jsonb_build_object('name','Synthetic other route '||n,'publicLabel','Synthetic other route '||n,
     'pointType','gathering','privateAddress','FICTIEF BROWSERSTARTADRES','geocodedLatitude',52.1+n*0.0001,'geocodedLongitude',4.27+n*0.0001,'active',true,'maxGroups',1,'maxChildren',30),null,'Andere synthetische gezinnen behouden in de gezamenlijke browserroute')->>'id')::uuid;
    perform api.admin_startregie_confirm_point('${eventSlug}',point,(select version from app_private.start_points where id=point));
    update app_private.event_route_settings set finale_planning_transfer_seconds=transfer+n*spacing where event_id=eid;
    schedule:=(api.admin_startregie_move_group(g.id,point,slot_time,(select version from app_private.walking_groups where id=g.id),'neutral','Afzonderlijke synthetische start en finale expliciet voorbereiden')->>'id')::uuid;
    perform api.admin_startregie_confirm_and_send('${eventSlug}',jsonb_build_array(jsonb_build_object('id',schedule,'revision',(select revision from app_private.group_schedule_revisions where id=schedule))),
     (select settings_version from app_private.events where id=eid),gen_random_uuid()::text);
   end loop;
   update app_private.event_route_settings set finale_planning_transfer_seconds=transfer where event_id=eid;
  end $fixture$;`);
}

/** Real authenticated input and the production planner/apply path. Reading a
 * snapshot never creates the route that the browser regression needs. */
export async function reviewCanonicalFixtureRoutes(client: SupabaseClient, eventSlug: string) {
  requireLocalTogetherDatabase();
  const input = await client.schema("api").rpc("admin_joint_route_planning_input", { _event_slug: eventSlug });
  expect(input.error, JSON.stringify(input.error)).toBeNull();
  const proposal = proposeJointRoutes(input.data as JointRouteInput);
  expect(proposal.valid, JSON.stringify(proposal.conflicts)).toBe(true);
  const applied = await client.schema("api").rpc("admin_joint_route_plan_apply", { _event_slug: eventSlug, _proposal: proposal, _confirmed: true,
    _reason: "Synthetische browserroute expliciet gezamenlijk berekend en beoordeeld", _idempotency_key: randomUUID() });
  expect(applied.error, JSON.stringify(applied.error)).toBeNull();
  return proposal;
}
