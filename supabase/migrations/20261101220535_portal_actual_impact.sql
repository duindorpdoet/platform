-- Physical impact is a projection of saved arrival evidence. Deployment does
-- not create visits, attendance, seals, event closures, messages or mail.
set lock_timeout='5s';

create function app_private.portal_actual_visits(_portal_id uuid)
returns table(group_id uuid,group_code text,arrived_at timestamptz,child_ids uuid[])
language sql stable security invoker set search_path='' as $$
 with target as materialized(
  select id,event_id from app_private.portals where id=_portal_id
 ), stops as materialized(
  select s.id,s.run_id,r.group_id,g.system_code,g.event_id,s.state,s.outcome
  from target p join app_private.walking_groups g on g.event_id=p.event_id
  join app_private.group_runs r on r.group_id=g.id
  join app_private.run_stops s on s.run_id=r.id
  left join app_private.route_plan_stops planned on planned.id=s.plan_stop_id
  where coalesce(s.portal_id,planned.portal_id)=p.id
 ), arrivals as materialized(
  select s.id,s.run_id,s.group_id,a.child_id,a.arrived_at
  from stops s join app_private.run_stop_arrivals a on a.run_stop_id=s.id
   and a.run_id=s.run_id and a.event_id=s.event_id and a.arrived
 ), proof as(
  select s.group_id,s.system_code,a.arrived_at
   from arrivals a join stops s on s.id=a.id
  union all
  -- The canonical ledger also retains reviewed historical group visits for
  -- which no individual child arrival was recorded. Never infer those children.
  select s.group_id,s.system_code,v.arrived_at
   from target p join app_private.group_portal_visits v on v.event_id=p.event_id and v.portal_id=p.id
   join stops s on s.id=v.first_stop_id and s.group_id=v.group_id
  union all
  -- Support the pre-ledger completion path, requiring its real portal scan.
  -- A scan alone, an abandoned stop or a system skip is not a completed visit.
  select s.group_id,s.system_code,e.scanned_at
   from stops s join app_private.scan_evidence e on e.run_stop_id=s.id
   join app_private.portal_credentials c on c.id=e.credential_id
   join target p on p.id=c.portal_id
   where s.state='completed' and s.outcome in('visited','mixed','all_skipped')
  union all
  -- A Duinpad receipt is immutable physical confirmation, independent of any
  -- show/relay attempt. Its child counts still come only from arrival records.
  select s.group_id,s.system_code,d.recorded_at
   from stops s join app_private.duinpad_finale_receipts d on d.run_stop_id=s.id
    and d.run_id=s.run_id and d.group_id=s.group_id and d.event_id=s.event_id
   join app_private.portal_credentials c on c.id=d.credential_id
   join target p on p.id=c.portal_id
 ), groups as(
  select proof.group_id,proof.system_code,min(proof.arrived_at)arrived_at
  from proof group by proof.group_id,proof.system_code
 )
 select g.group_id,g.system_code,g.arrived_at,
  coalesce((select array_agg(distinct a.child_id order by a.child_id)from arrivals a where a.group_id=g.group_id),'{}'::uuid[])
 from groups g
$$;
revoke all on function app_private.portal_actual_visits(uuid) from public,anon,authenticated,service_role;

-- Preserve the existing authenticated endpoint, definer boundary and owner /
-- event authorization. CREATE OR REPLACE preserves its existing execute ACL.
create or replace function api.portal_visits_snapshot(_portal_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare arrivals jsonb; visits jsonb; recap jsonb;
begin
 perform app_private.poortkamer_require(_portal_id);
 arrivals:=api.portal_arrivals_snapshot(_portal_id);
 with confirmed as materialized(
  select * from app_private.portal_actual_visits(_portal_id)
 ), gaps as(select arrived_at-lag(arrived_at)over(order by arrived_at,group_id)gap from confirmed),
 pause_history as(select state,created_at,lead(created_at,1,now())over(order by created_at,id)ended
  from app_private.portal_status_history where portal_id=_portal_id)
 select coalesce((select jsonb_agg(jsonb_build_object('groupCode',group_code,'visitedAt',arrived_at,'children',cardinality(child_ids))order by arrived_at desc,group_id)
  from(select * from confirmed order by arrived_at desc,group_id limit 200)bounded),'[]'::jsonb),
 jsonb_build_object('groups',(select count(*)from confirmed),
  'children',(select count(distinct child_id)from confirmed cross join lateral unnest(child_ids)child_id),
  'firstVisit',(select min(arrived_at)from confirmed),'lastVisit',(select max(arrived_at)from confirmed),
  'averageGapMinutes',(select round(extract(epoch from avg(gap))/60,1)from gaps),
  'busiestHalfHour',(select date_bin('30 minutes',arrived_at,'2026-01-01'::timestamptz)from confirmed group by 1 order by count(*)desc,1 limit 1),
  'pauses',(select count(*)from pause_history where state='paused'),
  'pauseMinutes',(select round(coalesce(sum(extract(epoch from ended-created_at))/60,0),1)from pause_history where state='paused'))
 into visits,recap;
 return jsonb_build_object('arrivals',coalesce((select jsonb_agg(x)from jsonb_array_elements(arrivals->'arrivals')x
  where x->>'state'<>'completed' and not exists(select 1 from jsonb_array_elements(visits)v where v->>'groupCode'=x->>'groupCode')),'[]'::jsonb),
  'visits',visits,'recap',recap,'updatedAt',now());
end $$;

-- Keep all current room/reception-policy behavior and expose the same totals
-- explicitly to the impact card and its locally generated share certificate.
create or replace function api.portal_room_snapshot(_event_slug text,_portal_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; pid uuid;
begin
 result:=api.portal_room_snapshot_before_reception_policy(_event_slug,_portal_id);
 pid:=(result#>>'{portal,id}')::uuid;
 if pid is null then return result;end if;
 result:=jsonb_set(result,'{portal}',(result->'portal')||app_private.portal_planning_policy(pid)
  ||jsonb_build_object('canManagePlanningPolicy',app_private.portal_planning_policy_can_manage(pid)));
 return result||jsonb_build_object('canManagePlanningPolicy',app_private.portal_planning_policy_can_manage(pid),
  'impact',jsonb_build_object('actualGroups',coalesce((result#>>'{visits,recap,groups}')::integer,0),
   'actualChildren',coalesce((result#>>'{visits,recap,children}')::integer,0)));
end $$;
