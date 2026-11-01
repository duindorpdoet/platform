-- The certificate describes registered planning, separately from real arrivals.
-- Projection only: no route, membership, history, mail or campaign is changed.
set lock_timeout='5s';

create function app_private.portal_registered_impact(_portal_id uuid)returns jsonb
language sql stable security invoker set search_path=''as $$
 with target as materialized(select id,event_id from app_private.portals where id=_portal_id),
 publications as materialized(
  select distinct on(p.group_id)p.*from app_private.group_start_publications p join target t on t.event_id=p.event_id
  where not exists(select 1 from app_private.group_start_withdrawals w where w.group_id=p.group_id and w.through_publication_order>=p.publication_order)
  order by p.group_id,p.publication_order desc
 ),groups as materialized(
  -- Organization closure changes live groups to stopped. It does not withdraw
  -- their registered route or published composition, so stopped is not excluded.
  select g.*,pub.schedule_id published_schedule_id,pub.starts_at published_starts_at,pub.point_snapshot
  from target t join app_private.walking_groups g on g.event_id=t.event_id and g.retired_at is null
  join publications pub on pub.group_id=g.id
 ),children as materialized(
  select distinct g.id group_id,rc.child_id from groups g
  join app_private.group_registrations a on a.group_id=g.id and a.superseded_at is null and a.published_at is not null
  join app_private.registrations r on r.id=a.registration_id and r.event_id=g.event_id and r.status='submitted'
  join app_private.registration_children rc on rc.registration_id=r.id and rc.event_id=g.event_id and rc.participation_status='active'
 ),accepted as materialized(
  select g.id group_id,g.event_id,g.published_starts_at,g.point_snapshot,plan
  from groups g join app_private.live_route_plans current on current.group_id=g.id and current.event_id=g.event_id
   and current.schedule_id is not distinct from g.published_schedule_id
  join app_private.joint_route_plan_versions version on version.id=current.accepted_version_id and version.event_id=g.event_id and version.plan_hash=current.plan_hash
  cross join lateral jsonb_array_elements(version.group_plans)plan where plan->>'groupId'=g.id::text
 ),joint_visits as(
  select a.group_id from accepted a cross join lateral jsonb_array_elements(a.plan->'visits')expected
  join app_private.live_route_visits v on v.group_id=a.group_id and v.event_id=a.event_id and v.retired_at is null
   and v.portal_id=(expected->>'portalId')::uuid and v.kind=expected->>'kind'
   and v.starts_at=(expected->>'startsAt')::timestamptz and v.duration_seconds=(expected->>'visitSeconds')::integer
   and v.buffer_seconds=(expected->>'bufferSeconds')::integer
  join target t on t.id=v.portal_id where expected->>'kind'in('ordinary','finale')
 ),joint_starts as(
  -- A frozen published house may also be the registered gathering place.
  -- UNION below counts that group once if an ordinary stop has the same portal.
  select a.group_id from accepted a join app_private.live_route_visits v on v.group_id=a.group_id and v.event_id=a.event_id
   and v.kind='start'and v.retired_at is null and v.starts_at=a.published_starts_at
   and v.portal_id=(a.point_snapshot->>'linked_portal_id')::uuid
  join target t on t.id=v.portal_id where(a.plan->>'startsAt')::timestamptz=a.published_starts_at
 ),legacy as materialized(
  select g.*from groups g join app_private.route_plan_versions version on version.id=g.current_plan_version_id and version.group_id=g.id
   and version.state='published'and version.published_at is not null
  where g.route_mode='legacy'and not exists(select 1 from app_private.live_route_plans p where p.group_id=g.id and p.accepted_version_id is not null)
 ),planned_groups as(
  select group_id from joint_visits union select group_id from joint_starts
  union select g.id from legacy g join app_private.route_plan_stops stop on stop.plan_version_id=g.current_plan_version_id join target t on t.id=stop.portal_id
  union select g.id from legacy g join target t on t.id=(g.point_snapshot->>'linked_portal_id')::uuid
 ),registered as materialized(
  select distinct planned.group_id,c.child_id from planned_groups planned join children c on c.group_id=planned.group_id
 )
 select jsonb_build_object('registeredGroups',count(distinct group_id),'registeredChildren',count(distinct child_id))from registered
$$;
revoke all on function app_private.portal_registered_impact(uuid)from public,anon,authenticated,service_role;

-- Same installed room wrapper, same existing owner/event authorization and ACL.
-- Keep the actual-arrival contract unchanged; add registered planning alongside.
create or replace function api.portal_room_snapshot(_event_slug text,_portal_id uuid default null)returns jsonb
language plpgsql security definer set search_path=''as $$
declare result jsonb;pid uuid;
begin
 result:=api.portal_room_snapshot_before_reception_policy(_event_slug,_portal_id);
 pid:=(result#>>'{portal,id}')::uuid;
 if pid is null then return result;end if;
 result:=jsonb_set(result,'{portal}',(result->'portal')||app_private.portal_planning_policy(pid)
  ||jsonb_build_object('canManagePlanningPolicy',app_private.portal_planning_policy_can_manage(pid)));
 return result||jsonb_build_object('canManagePlanningPolicy',app_private.portal_planning_policy_can_manage(pid),
  'impact',jsonb_build_object('actualGroups',coalesce((result#>>'{visits,recap,groups}')::integer,0),
   'actualChildren',coalesce((result#>>'{visits,recap,children}')::integer,0)),
  'registeredImpact',app_private.portal_registered_impact(pid));
end $$;
-- CREATE OR REPLACE preserves the existing authenticated-only room RPC grants.
notify pgrst,'reload schema';
