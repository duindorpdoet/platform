-- Explicitly accepted route intentions. Deployment never accepts, publishes,
-- recalculates or changes a participant's route or a started journey.
set lock_timeout='5s';
create table app_private.joint_route_plan_versions(
 id uuid primary key default gen_random_uuid(),event_id uuid not null references app_private.events(id),
 revision integer not null check(revision>0),source_hash text not null,plan_hash text not null,board_hash text not null,
 policy_version text not null,accepted_by uuid not null references auth.users(id),accepted_at timestamptz not null default clock_timestamp(),
 group_plans jsonb not null check(jsonb_typeof(group_plans)='array'),metrics jsonb not null default '{}',
 reason text not null check(char_length(reason) between 10 and 500),unique(event_id,revision)
);
alter table app_private.joint_route_plan_versions enable row level security;
revoke all on app_private.joint_route_plan_versions from public,anon,authenticated;
alter table app_private.live_route_plans
 add column accepted_version_id uuid references app_private.joint_route_plan_versions(id),
 add column source_hash text,add column plan_hash text;
alter table app_private.group_runs add column accepted_route_version_id uuid references app_private.joint_route_plan_versions(id);
create function app_private.preserve_joint_route_plan_version() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'ACCEPTED_ROUTE_VERSION_IMMUTABLE' using errcode='23514';end $$;
create trigger preserve_joint_route_plan_version before update or delete on app_private.joint_route_plan_versions
 for each row execute function app_private.preserve_joint_route_plan_version();
revoke all on function app_private.preserve_joint_route_plan_version() from public,anon,authenticated;

-- Exact UTF-8 digest contract shared with jointRouteProposalDigestText in TS.
create function app_private.joint_route_proposal_hash(_source text,_board text,_plans jsonb) returns text
language sql immutable set search_path='' as $$
 select encode(extensions.digest(convert_to(coalesce(_source,'')||chr(10)||coalesce(_board,'')||coalesce((
  select string_agg(chr(10)||(plan->>'groupId')||chr(10)||(plan->>'startsAt')||coalesce((
   select string_agg(chr(10)||(visit->>'portalId')||chr(10)||(visit->>'kind')||chr(10)||(visit->>'startsAt')||chr(10)||(visit->>'visitSeconds')||chr(10)||(visit->>'bufferSeconds'),'' order by (visit->>'sequence')::integer)
   from jsonb_array_elements(plan->'visits') visit),'') ,'' order by plan->>'groupId')
  from jsonb_array_elements(_plans) plan),''),'UTF8'),'sha256'),'hex')
$$;

-- Revalidate the complete submitted physical calendar, not its client score.
-- _input is obtained under the command's event/dispatch lock from the same pure
-- projector used by the proposal endpoint; no client may supply policy inputs.
create function app_private.validate_joint_route_proposal(_input jsonb,_plans jsonb) returns void
language plpgsql stable security definer set search_path='' as $$
declare plan jsonb; expected jsonb; visit jsonb; portal jsonb; leg jsonb; win jsonb;
 calendar jsonb:=coalesce(_input->'fixedVisits','[]');gid uuid;pid uuid;physical uuid;visited uuid[];
 children integer;position integer;ordinary integer;finales integer;walking integer;seconds integer;buffer integer;
 start_at timestamptz;cursor_at timestamptz;finish_at timestamptz;node text;occupied jsonb;needed_step_free boolean;
begin
 if jsonb_typeof(_plans) is distinct from 'array' or jsonb_array_length(_plans)>500 then raise exception 'INVALID_JOINT_ROUTE_PROPOSAL' using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(coalesce(_input->'diagnostics','[]')) d where d->>'severity'='block') then
  raise exception 'JOINT_ROUTE_INPUT_BLOCKED' using errcode='23514',detail=(_input->'diagnostics')::text;end if;
 if jsonb_array_length(_plans)<>jsonb_array_length(_input->'groups') or exists(
  select 1 from jsonb_array_elements(_input->'groups') g where (select count(*) from jsonb_array_elements(_plans) p where p->>'groupId'=g->>'id')<>1) then
  raise exception 'JOINT_ROUTE_GROUP_SET_CHANGED' using errcode='23514';end if;
 for plan in select * from jsonb_array_elements(_plans) loop
  if jsonb_typeof(plan->'visits') is distinct from 'array' or jsonb_array_length(plan->'visits') not between 1 and 100 then raise exception 'INVALID_JOINT_ROUTE_PROPOSAL' using errcode='22023';end if;
  select * into expected from jsonb_array_elements(_input->'groups') g where g->>'id'=plan->>'groupId';
  if expected is null then raise exception 'JOINT_ROUTE_GROUP_SET_CHANGED' using errcode='23514';end if;
  calendar:=calendar||coalesce((select jsonb_agg(v||jsonb_build_object('groupId',plan->>'groupId','children',(expected->>'childCount')::integer)) from jsonb_array_elements(plan->'visits') v),'[]');
 end loop;
 for plan in select * from jsonb_array_elements(_plans) order by value->>'groupId' loop
  gid:=(plan->>'groupId')::uuid;
  select * into expected from jsonb_array_elements(_input->'groups') g where g->>'id'=gid::text;
  children:=(expected->>'childCount')::integer;cursor_at:=(expected->>'startsAt')::timestamptz;node:=expected->>'startNodeId';
  if not isfinite(cursor_at) or (plan->>'startsAt')::timestamptz is distinct from cursor_at then raise exception 'START_APPOINTMENT_CHANGED' using errcode='23514';end if;
  position:=0;ordinary:=0;finales:=0;walking:=0;
  select coalesce(array_agg(coalesce(app_private.portal_physical_identity(x::uuid),x::uuid)),'{}') into visited from jsonb_array_elements_text(expected->'excludedPortalIds') x;
  if expected->>'fixedFirstPortalId' is not null and (plan->'visits'->0->>'portalId') is distinct from expected->>'fixedFirstPortalId'
   and coalesce((expected->>'maxOrdinaryVisits')::integer,-1)<>0 and not exists(select 1 from jsonb_array_elements(coalesce(plan->'diagnostics','[]')) d where d->>'code' in('FIRST_PORTAL_ALTERNATIVE','FIXED_FIRST_PORTAL_REPLACED')) then
   raise exception 'FIRST_PORTAL_ALTERNATIVE_REVIEW_REQUIRED' using errcode='23514';end if;
  for visit in select * from jsonb_array_elements(plan->'visits') order by (value->>'sequence')::integer loop
   position:=position+1;pid:=(visit->>'portalId')::uuid;physical:=app_private.portal_physical_identity(pid);
   if (visit->>'sequence')::integer<>position or visit->>'kind' not in('ordinary','finale') or finales>0 then raise exception 'INVALID_ROUTE_SEQUENCE' using errcode='23514';end if;
   select * into portal from jsonb_array_elements(_input->'portals') p where p->>'id'=pid::text;
   if portal is null or physical is null then raise exception 'PORTAL_UNAVAILABLE' using errcode='23514';end if;
   if physical=any(visited) then raise exception 'DUPLICATE_PHYSICAL_VISIT' using errcode='23514';end if;
   visited:=array_append(visited,physical);
   needed_step_free:=coalesce((expected->>'requiresStepFree')::boolean,false) or coalesce((expected->>'accessibilityNeedsReview')::boolean,false);
   if needed_step_free and portal->>'accessibilityStatus'<>'step_free' then raise exception 'ACCESSIBILITY_UNSUITABLE' using errcode='23514';end if;
   select * into leg from jsonb_array_elements(_input->'legs') l where l->>'from'=node and l->>'to'=portal->>'nodeId';
   start_at:=(visit->>'startsAt')::timestamptz;seconds:=(visit->>'visitSeconds')::integer;buffer:=(visit->>'bufferSeconds')::integer;
   if not isfinite(start_at) or seconds not between 30 and 7200 or buffer not between 0 and 3600 or leg is null
    or start_at<cursor_at+make_interval(secs=>(leg->>'seconds')::integer)
    or (visit->>'walkSeconds')::integer is distinct from (leg->>'seconds')::integer
    or (visit->>'walkMeters')::integer is distinct from (leg->>'meters')::integer then raise exception 'ROUTE_TRAVEL_TIME_INVALID' using errcode='23514';end if;
   walking:=walking+(leg->>'seconds')::integer;
   if (leg->>'seconds')::integer>(_input->>'maxLegWalkingSeconds')::integer or walking>(_input->>'maxTotalWalkingSeconds')::integer then raise exception 'ROUTE_WALKING_BUDGET' using errcode='23514';end if;
   finish_at:=start_at+make_interval(secs=>seconds);
   select * into win from jsonb_array_elements(portal->'windows') w where start_at>=(w->>'opensAt')::timestamptz
    and case when visit->>'kind'='finale' then start_at<=(w->>'arrivalClosesAt')::timestamptz else start_at<(w->>'arrivalClosesAt')::timestamptz end
    and finish_at+make_interval(secs=>buffer)<=(w->>'closesAt')::timestamptz
    and seconds=(w->>'visitSeconds')::integer and buffer=(w->>'bufferSeconds')::integer and children<=(w->>'maxChildren')::integer limit 1;
   if win is null then raise exception 'PORTAL_EFFECTIVE_WINDOW_CONFLICT' using errcode='23514';end if;
   select coalesce(jsonb_agg(jsonb_build_object('group_id',c->>'groupId','starts_at',c->>'startsAt',
    'ends_at',(c->>'startsAt')::timestamptz+make_interval(secs=>(c->>'visitSeconds')::integer+(c->>'bufferSeconds')::integer),'child_count',(c->>'children')::integer)),'[]') into occupied
   from jsonb_array_elements(calendar) c where c->>'kind'<>'start' and app_private.portal_physical_identity((c->>'portalId')::uuid)=physical;
   if not app_private.portal_interval_available_from_occupancy(pid,gid,start_at,finish_at+make_interval(secs=>buffer),children,occupied) then raise exception 'JOINT_ROUTE_ARRIVAL_OR_CAPACITY_CONFLICT' using errcode='23514',detail=jsonb_build_object('groupId',gid,'portalId',pid,'startsAt',start_at)::text;end if;
   if visit->>'kind'='ordinary' then
    ordinary:=ordinary+1;
    if coalesce((portal->>'finale')::boolean,false) or finish_at>(expected->>'ordinaryStopAt')::timestamptz then raise exception 'ORDINARY_STOP_LIMIT' using errcode='23514';end if;
   else
    finales:=finales+1;
    if not coalesce((portal->>'finale')::boolean,false) or pid is distinct from (expected#>>'{finale,portalId}')::uuid
     or not coalesce((expected#>>'{finale,reservationValid}')::boolean,false)
     or start_at is distinct from (expected#>>'{finale,reservedAt}')::timestamptz then raise exception 'FINALE_APPOINTMENT_CHANGED' using errcode='23514';end if;
    if start_at>(expected#>>'{finale,latestArrivalAt}')::timestamptz
     or finish_at>(expected->>'desiredEndAt')::timestamptz+make_interval(secs=>(_input->>'maxGroupOverrunSeconds')::integer) then raise exception 'GROUP_COMPLETION_LIMIT' using errcode='23514';end if;
    if (plan->>'finaleArrivalAt')::timestamptz is distinct from start_at or (plan->>'expectedCompletionAt')::timestamptz is distinct from finish_at then raise exception 'FINALE_TIMING_MISMATCH' using errcode='23514';end if;
   end if;
   cursor_at:=finish_at;node:=portal->>'nodeId';
  end loop;
  if finales<>1 then raise exception 'FINALE_REQUIRED' using errcode='23514';end if;
  if ordinary=0 and coalesce((expected->>'maxOrdinaryVisits')::integer,-1)<>0 then raise exception 'NO_FEASIBLE_ORDINARY_VISIT' using errcode='23514';end if;
  if expected->>'maxOrdinaryVisits' is not null and ordinary>(expected->>'maxOrdinaryVisits')::integer then raise exception 'ORDINARY_VISIT_LIMIT' using errcode='23514';end if;
 end loop;
end $$;

create function app_private.canonical_route_group_plan(_group uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select plan from app_private.live_route_plans p join app_private.joint_route_plan_versions version on version.id=p.accepted_version_id
 cross join lateral jsonb_array_elements(version.group_plans) plan where p.group_id=_group and plan->>'groupId'=_group::text
$$;
create function app_private.canonical_route_group_current(_group uuid,_source_hash text default null) returns boolean
language sql stable security definer set search_path='' as $$
 with source as(select p.*,v.group_plans,v.plan_hash accepted_hash from app_private.live_route_plans p
  join app_private.joint_route_plan_versions v on v.id=p.accepted_version_id where p.group_id=_group),
 plan as(select item from source cross join lateral jsonb_array_elements(group_plans) item where item->>'groupId'=_group::text),
 actual as(select v.*,row_number()over(order by sequence) canonical_sequence from app_private.live_route_visits v where v.group_id=_group and v.retired_at is null and v.kind<>'start')
 select coalesce((select source.source_hash=coalesce(_source_hash,app_private.joint_route_source_hash(source.event_id))
  and source.plan_hash=source.accepted_hash and source.schedule_id is not distinct from (app_private.route_group_start_context(_group)->>'scheduleId')::uuid
  and(select count(*) from actual)=jsonb_array_length(plan.item->'visits')
  and not exists(select 1 from jsonb_array_elements(plan.item->'visits') expected left join actual on actual.canonical_sequence=(expected->>'sequence')::integer
   where actual.id is null or actual.portal_id is distinct from (expected->>'portalId')::uuid or actual.kind is distinct from expected->>'kind'
    or actual.starts_at is distinct from (expected->>'startsAt')::timestamptz or actual.duration_seconds is distinct from (expected->>'visitSeconds')::integer or actual.buffer_seconds is distinct from (expected->>'bufferSeconds')::integer)
 from source cross join plan),false)
$$;

create function api.admin_joint_route_plan_apply(_event_slug text,_proposal jsonb,_confirmed boolean,_reason text,_idempotency_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e app_private.events; input jsonb; old app_private.command_receipts;hashed text;digest text;version app_private.joint_route_plan_versions;
 plan jsonb;visit jsonb;ctx jsonb;gid uuid;seq integer;offset_seq integer;visit_count integer:=0;group_count integer:=0;result jsonb;
begin
 select * into e from app_private.events where slug=_event_slug for no key update;
 if auth.uid() is null or e.id is null or not(app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'groups_manage',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if not coalesce(_confirmed,false) or char_length(trim(coalesce(_reason,''))) not between 10 and 500
  or coalesce(_idempotency_key,'')!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  or jsonb_typeof(_proposal) is distinct from 'object' or octet_length(_proposal::text)>2000000 then raise exception 'JOINT_ROUTE_CONFIRMATION_REQUIRED' using errcode='22023';end if;
 hashed:=encode(extensions.digest(jsonb_build_array(e.id,_proposal,_confirmed,trim(_reason))::text,'sha256'),'hex');
 select * into old from app_private.command_receipts where actor_id=auth.uid() and command_type='joint_route.apply' and idempotency_key=_idempotency_key;
 if old.id is not null then if old.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505';end if;return old.safe_result;end if;
 perform pg_advisory_xact_lock(hashtextextended(e.id::text||':route-dispatch',0));
 input:=api.admin_joint_route_planning_input(_event_slug);
 if _proposal->>'sourceHash' is distinct from input->>'sourceHash' or _proposal->>'boardHash' is distinct from input->>'boardHash'
  or _proposal->>'policyVersion' is distinct from input->>'policyVersion' then raise exception 'JOINT_ROUTE_PROPOSAL_STALE' using errcode='40001';end if;
 if (_proposal->>'valid')::boolean is distinct from true then raise exception 'JOINT_ROUTE_PROPOSAL_BLOCKED' using errcode='23514';end if;
 perform 1 from app_private.walking_groups where event_id=e.id and id in(select(g->>'groupId')::uuid from jsonb_array_elements(_proposal->'groups') g) order by id for update;
 if exists(select 1 from jsonb_array_elements(_proposal->'groups') g where app_private.admin_registration_group_started((g->>'groupId')::uuid)) then raise exception 'GROUP_ALREADY_STARTED' using errcode='23514';end if;
 if exists(select 1 from app_private.live_route_visits v where v.group_id in(select(g->>'groupId')::uuid from jsonb_array_elements(_proposal->'groups') g) and v.run_stop_id is not null) then raise exception 'VISIT_PROTECTED' using errcode='23514';end if;
 perform app_private.validate_joint_route_proposal(input,_proposal->'groups');
 digest:=app_private.joint_route_proposal_hash(input->>'sourceHash',input->>'boardHash',_proposal->'groups');
 if digest is distinct from _proposal->>'proposalHash' then raise exception 'JOINT_ROUTE_HASH_MISMATCH' using errcode='23514';end if;
 insert into app_private.joint_route_plan_versions(event_id,revision,source_hash,plan_hash,board_hash,policy_version,accepted_by,group_plans,metrics,reason)
 select e.id,coalesce(max(revision),0)+1,input->>'sourceHash',digest,input->>'boardHash',input->>'policyVersion',auth.uid(),_proposal->'groups',coalesce(_proposal->'metrics','{}'),trim(_reason)
 from app_private.joint_route_plan_versions where event_id=e.id returning * into version;
 for plan in select * from jsonb_array_elements(_proposal->'groups') order by value->>'groupId' loop
  gid:=(plan->>'groupId')::uuid;ctx:=app_private.route_group_start_context(gid);offset_seq:=0;group_count:=group_count+1;
  insert into app_private.live_route_plans(group_id,event_id,schedule_id,accepted_version_id,source_hash,plan_hash)
   values(gid,e.id,(ctx->>'scheduleId')::uuid,version.id,version.source_hash,version.plan_hash)
  on conflict(group_id) do update set schedule_id=excluded.schedule_id,accepted_version_id=excluded.accepted_version_id,source_hash=excluded.source_hash,plan_hash=excluded.plan_hash,version=live_route_plans.version+1;
  if ctx#>>'{pointSnapshot,linked_portal_id}' is not null and not coalesce((ctx#>>'{pointSnapshot,counts_as_first_portal_visit}')::boolean,false) then
   offset_seq:=1;
   insert into app_private.live_route_visits(event_id,group_id,sequence,portal_id,starts_at,duration_seconds,buffer_seconds,kind,source)
   values(e.id,gid,1,(ctx#>>'{pointSnapshot,linked_portal_id}')::uuid,(plan->>'startsAt')::timestamptz,30,0,'start','manual')
   on conflict(group_id,sequence) do update set portal_id=excluded.portal_id,starts_at=excluded.starts_at,duration_seconds=30,buffer_seconds=0,kind='start',source='manual',retired_at=null,version=live_route_visits.version+1,updated_at=clock_timestamp();
  end if;
  for visit in select * from jsonb_array_elements(plan->'visits') order by(value->>'sequence')::integer loop
   seq:=(visit->>'sequence')::integer+offset_seq;visit_count:=visit_count+1;
   insert into app_private.live_route_visits(event_id,group_id,sequence,portal_id,starts_at,duration_seconds,buffer_seconds,kind,source)
   values(e.id,gid,seq,(visit->>'portalId')::uuid,(visit->>'startsAt')::timestamptz,(visit->>'visitSeconds')::integer,(visit->>'bufferSeconds')::integer,visit->>'kind','manual')
   on conflict(group_id,sequence) do update set portal_id=excluded.portal_id,starts_at=excluded.starts_at,duration_seconds=excluded.duration_seconds,buffer_seconds=excluded.buffer_seconds,kind=excluded.kind,source='manual',retired_at=null,version=live_route_visits.version+1,updated_at=clock_timestamp();
  end loop;
  update app_private.live_route_visits set retired_at=clock_timestamp(),version=live_route_visits.version+1 where group_id=gid and retired_at is null and sequence>jsonb_array_length(plan->'visits')+offset_seq;
 end loop;
 result:=jsonb_build_object('acceptedVersionId',version.id,'revision',version.revision,'sourceHash',version.source_hash,'proposalHash',version.plan_hash,
  'boardHash',app_private.live_planboard_hash(e.id),'groupCount',group_count,'visitCount',visit_count,'changed',true);
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(e.id,auth.uid(),'route.joint_proposal.accepted','event',e.id,jsonb_build_object('acceptedVersionId',version.id,'proposalHash',digest,'groups',group_count,'visits',visit_count,'reason',trim(_reason)));
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(auth.uid(),'joint_route.apply',_idempotency_key,hashed,result,now()+interval '30 days');
 perform realtime.send(jsonb_build_object('resource','route_intent'),'snapshot_changed','admin-event:'||e.id,true);
 return result;
end $$;
revoke all on function api.admin_joint_route_plan_apply(text,jsonb,boolean,text,text) from public,anon;
grant execute on function api.admin_joint_route_plan_apply(text,jsonb,boolean,text,text) to authenticated;
revoke all on function app_private.joint_route_proposal_hash(text,text,jsonb),app_private.validate_joint_route_proposal(jsonb,jsonb),app_private.canonical_route_group_plan(uuid),app_private.canonical_route_group_current(uuid,text) from public,anon,authenticated;

-- Snapshot reads initialize only cheap headers and attach authoritative stop
-- identities. They never build independent nearest-house routes.
create or replace function app_private.live_planboard_seed(_event uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 insert into app_private.live_route_plans(group_id,event_id,schedule_id)
 select g.id,g.event_id,coalesce(run.schedule_revision_id,(app_private.route_group_start_context(g.id)->>'scheduleId')::uuid)
 from app_private.walking_groups g left join lateral(select r.* from app_private.group_runs r where r.group_id=g.id and r.status in('live','paused') order by r.created_at desc,r.id desc limit 1) run on true
 where g.event_id=_event and g.retired_at is null and(g.current_schedule_revision_id is not null or g.current_plan_version_id is not null)
 on conflict(group_id) do nothing;
 update app_private.live_route_visits v set run_stop_id=s.id,version=v.version+1
 from(select distinct on(group_id)* from app_private.group_runs order by group_id,case when status in('live','paused') then 0 else 1 end,created_at desc,id desc)r
 join app_private.run_stops s on s.run_id=r.id left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
 where v.event_id=_event and v.group_id=r.group_id and v.kind<>'start' and v.portal_id=coalesce(s.portal_id,ps.portal_id) and v.run_stop_id is null
 and not exists(select 1 from app_private.live_route_visits linked where linked.run_stop_id=s.id)
 and not exists(select 1 from app_private.run_stops newer left join app_private.route_plan_stops np on np.id=newer.plan_stop_id
  where newer.run_id=r.id and coalesce(newer.portal_id,np.portal_id)=v.portal_id and(newer.sequence,newer.opened_at,newer.id)>(s.sequence,s.opened_at,s.id));
end $$;

alter function app_private.start_ops_route_preview(uuid) rename to start_ops_route_preview_before_joint_routes;
revoke all on function app_private.start_ops_route_preview_before_joint_routes(uuid) from public,anon,authenticated;
create function app_private.start_ops_route_preview(_group_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare g app_private.walking_groups;ctx jsonb;point jsonb;origin jsonb;stops jsonb;warnings jsonb:='[]'::jsonb;accepted jsonb;version_id uuid;source_hash text;stale boolean;
begin
 select * into g from app_private.walking_groups where id=_group_id;
 if g.id is null then return null;end if;
 -- Preserve the existing journey's destination and history projection.
 if app_private.admin_registration_group_started(g.id) and not exists(select 1 from app_private.group_runs r where r.group_id=g.id and r.accepted_route_version_id is not null) then
  return app_private.start_ops_route_preview_before_joint_routes(g.id);end if;
 ctx:=app_private.route_group_start_context(g.id);point:=ctx->'pointSnapshot';
 origin:=app_private.routing_position((point->>'marker_latitude')::numeric,(point->>'marker_longitude')::numeric,(point->>'geocoded_latitude')::numeric,(point->>'geocoded_longitude')::numeric,(point->>'latitude')::numeric,(point->>'longitude')::numeric);
 select p.accepted_version_id,p.source_hash into version_id,source_hash from app_private.live_route_plans p where p.group_id=g.id;
 accepted:=app_private.canonical_route_group_plan(g.id);
 stale:=version_id is not null and not app_private.canonical_route_group_current(g.id);
 select coalesce(jsonb_agg(reason->>'message'),'[]'::jsonb) into warnings
 from jsonb_array_elements(app_private.start_publication_readiness(g.event_id)->'reasons') reason;
 if version_id is null then warnings:=warnings||jsonb_build_array('Bereken, beoordeel en sla eerst een gezamenlijk routevoorstel op. Deze opgeslagen intentie is niet opnieuw berekend.');
 elsif stale then warnings:=warnings||jsonb_build_array('De route-invoer of opgeslagen intentie is gewijzigd. Bereken en beoordeel een nieuw gezamenlijk voorstel; de bestaande tijden zijn behouden.');end if;
 with stored as(
  select v.portal_id,row_number()over(order by v.sequence)::integer sequence,v.starts_at,v.duration_seconds,v.buffer_seconds,v.kind,v.run_stop_id,
   (select (x->>'walkMeters')::integer from jsonb_array_elements(coalesce(accepted->'visits','[]')) x where x->>'portalId'=v.portal_id::text) walk_meters,
   (select (x->>'walkSeconds')::integer from jsonb_array_elements(coalesce(accepted->'visits','[]')) x where x->>'portalId'=v.portal_id::text) walk_seconds
  from app_private.live_route_visits v where v.group_id=g.id and v.retired_at is null and v.kind<>'start'
 ),fallback as(
  select ps.portal_id,ps.position,ps.planned_arrival_at,extract(epoch from ps.planned_departure_at-ps.planned_arrival_at)::integer,0,
   case when ps.position=(select max(position)from app_private.route_plan_stops where plan_version_id=g.current_plan_version_id)then 'finale' else 'ordinary'end,null::uuid,null::integer,null::integer
  from app_private.route_plan_stops ps where ps.plan_version_id=g.current_plan_version_id and g.route_mode='legacy' and not exists(select 1 from stored)
 ),actual as(select * from stored union all select * from fallback),positioned as(
  select a.*,lag(a.portal_id)over(order by a.sequence) previous_portal from actual a
 )
 select coalesce(jsonb_agg(jsonb_build_object('portalId',p.id,'code',p.system_code,'name',p.name,'address',concat_ws(' ',l.street,l.house_number,l.addition),
  'coordinate',app_private.routing_coordinate(app_private.portal_location(p.id)),'publicEntranceInstructions',app_private.portal_public_entrance(p.id),
  'world',case when a.kind='finale' then 'Finale' else world.name end,'kind',a.kind,'sequence',a.sequence,'walkMeters',coalesce(a.walk_meters,travel.distance_m),'walkMinutes',ceil(coalesce(a.walk_seconds,travel.duration_seconds)/60.0),
  'plannedArrivalAt',a.starts_at,'visitSeconds',a.duration_seconds,'bufferSeconds',a.buffer_seconds,
  'expectedCompletionAt',case when a.kind='finale'then a.starts_at+make_interval(secs=>a.duration_seconds)end,
  'physicalEndsAt',a.starts_at+make_interval(secs=>a.duration_seconds+a.buffer_seconds),
  'status',case when a.run_stop_id is not null then 'current' else 'expected'end)order by a.sequence),'[]')into stops
 from positioned a join app_private.portals p on p.id=a.portal_id join app_private.worlds world on world.id=p.world_id left join app_private.portal_private_locations l on l.portal_id=p.id
 left join lateral(select case when a.previous_portal is null then origin else app_private.portal_location(a.previous_portal)end value) previous on true
 left join lateral app_private.destination_estimate((previous.value->>'latitude')::numeric,(previous.value->>'longitude')::numeric,
  (app_private.portal_location(p.id)->>'latitude')::numeric,(app_private.portal_location(p.id)->>'longitude')::numeric) travel on a.walk_seconds is null;
 return jsonb_build_object('groupId',g.id,'revision',app_private.start_ops_route_revision(g.event_id),'generatedAt',statement_timestamp(),
  'acceptedVersionId',version_id,'sourceHash',source_hash,'sourceChanged',stale,'requiresJointReview',version_id is null or stale,
  'start',jsonb_build_object('pointId',point->'id','name',point->>'name','address',point->>'private_address','coordinate',app_private.routing_coordinate(origin),'arrivalInstructions',point->>'public_arrival_instructions','startsAt',ctx->'startsAt'),
  'stops',stops,'totalMeters',coalesce((select sum((x->>'walkMeters')::integer)from jsonb_array_elements(stops)x),0),
  'totalMinutes',coalesce((select ceil(sum((x->>'visitSeconds')::integer+coalesce((x->>'walkMinutes')::integer,0)*60)/60.0)from jsonb_array_elements(stops)x),0),
  'eligiblePortalCount',(select count(distinct app_private.portal_physical_identity(p.id))from app_private.portals p where p.event_id=g.event_id and p.approval_status='approved'and p.lifecycle_status='active'),
  'warnings',warnings,'provisional',true,'distanceMethod','straight_line','travelTimeEstimated',true,
  'hasConfirmedStart',coalesce((ctx->>'hasPublishedStart')::boolean,false)or app_private.is_start_confirmation_current((ctx->>'scheduleId')::uuid));
end $$;

alter function app_private.live_planboard_warnings_from_visits(uuid,jsonb,jsonb) rename to live_planboard_warnings_before_canonical_routes;
revoke all on function app_private.live_planboard_warnings_before_canonical_routes(uuid,jsonb,jsonb)from public,anon,authenticated;
create function app_private.live_planboard_warnings_from_visits(_event uuid,_changes jsonb,_visits jsonb)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare result jsonb;source text;notices jsonb;
begin
 result:=app_private.live_planboard_warnings_before_canonical_routes(_event,_changes,_visits);source:=app_private.joint_route_source_hash(_event);
 select coalesce(jsonb_agg(jsonb_build_object('code',case when p.accepted_version_id is null then 'JOINT_ROUTE_REVIEW_REQUIRED' else 'ACCEPTED_ROUTE_STALE'end,
  'severity','warning','message',case when p.accepted_version_id is null then 'Bereken, beoordeel en sla een gezamenlijk routevoorstel op voordat een nieuwe route begint.'else'De route-invoer of intentie is gewijzigd. Bereken en beoordeel een nieuw gezamenlijk voorstel.'end,
  'visitIds','[]'::jsonb,'groupIds',jsonb_build_array(g.id))),'[]')into notices
 from app_private.walking_groups g join app_private.live_route_plans p on p.group_id=g.id where g.event_id=_event and g.retired_at is null and not app_private.admin_registration_group_started(g.id)
 and(p.accepted_version_id is null or not app_private.canonical_route_group_current(g.id,source));
 result:=result||notices;
 return result;
end $$;

alter function api.admin_live_planboard_snapshot(text)rename to admin_live_planboard_snapshot_before_canonical_routes;
revoke all on function api.admin_live_planboard_snapshot_before_canonical_routes(text)from public,anon,authenticated;
create function api.admin_live_planboard_snapshot(_event_slug text)returns jsonb language plpgsql security definer set search_path=''as $$
declare result jsonb;source text;eid uuid;
begin
 result:=api.admin_live_planboard_snapshot_before_canonical_routes(_event_slug);eid:=(result->>'eventId')::uuid;source:=app_private.joint_route_source_hash(eid);
 result:=jsonb_set(result,'{groups}',coalesce((select jsonb_agg(g||jsonb_build_object('acceptedRouteVersionId',p.accepted_version_id,'routeSourceHash',p.source_hash,'routePlanHash',p.plan_hash,
  'routeSourceChanged',coalesce((g->>'routeSourceChanged')::boolean,false)or(not app_private.admin_registration_group_started((g->>'id')::uuid)and not app_private.canonical_route_group_current((g->>'id')::uuid,source))))
  from jsonb_array_elements(result->'groups')g left join app_private.live_route_plans p on p.group_id=(g->>'id')::uuid),'[]'));
 result:=jsonb_set(result,'{portals}',coalesce((select jsonb_agg(p||app_private.portal_planning_policy((p->>'id')::uuid)||jsonb_build_object('windows',coalesce((select jsonb_agg(jsonb_build_object(
  'opensAt',w.opens_at,'arrivalClosesAt',w.arrival_closes_at,'closesAt',case when w.is_finale then w.closes_at else w.arrival_closes_at end,'physicalClosesAt',w.closes_at,'maxGroups',w.max_groups,'maxChildren',w.max_children,'maxTotalChildren',w.max_total_children,
  'maxConcurrentChildren',w.max_concurrent_children,'durationSeconds',w.visit_seconds,'bufferSeconds',w.buffer_seconds,'headwaySeconds',w.headway_seconds))from app_private.portal_effective_windows((p->>'id')::uuid)w),'[]')))
  from jsonb_array_elements(result->'portals')p),'[]'));
 return result||jsonb_build_object('routeSourceHash',source,'jointRouteRequired',exists(select 1 from jsonb_array_elements(result->'groups')g where coalesce((g->>'routeSourceChanged')::boolean,false)));
end $$;
revoke all on function api.admin_live_planboard_snapshot(text)from public,anon;
grant execute on function api.admin_live_planboard_snapshot(text)to authenticated;
revoke all on function app_private.live_planboard_seed(uuid),app_private.start_ops_route_preview(uuid),app_private.live_planboard_warnings_from_visits(uuid,jsonb,jsonb)from public,anon,authenticated;

-- A deployment boundary distinguishes journeys already underway from newly
-- started runs. It stores policy metadata, and changes no existing journey.
create table app_private.joint_route_policy_releases(policy_version text primary key,activated_at timestamptz not null default clock_timestamp());
alter table app_private.joint_route_policy_releases enable row level security;
revoke all on app_private.joint_route_policy_releases from public,anon,authenticated;
insert into app_private.joint_route_policy_releases(policy_version)values('joint-reception-v1');

create function app_private.canonical_reserve_finale(_run uuid,_at timestamptz)returns uuid
language plpgsql security definer set search_path=''as $$
declare r app_private.group_runs;g app_private.walking_groups;settings app_private.event_route_settings;intent app_private.live_route_visits;
 children integer;existing app_private.portal_reservations;until_at timestamptz;rid uuid;
begin
 select * into r from app_private.group_runs where id=_run for update;
 select * into g from app_private.walking_groups where id=r.group_id;
 select * into settings from app_private.event_route_settings where event_id=g.event_id;
 select * into intent from app_private.live_route_visits where group_id=g.id and kind='finale'and retired_at is null order by sequence limit 1;
 select count(*)into children from app_private.run_participants where run_id=r.id and attendance='present'and departed_at is null;
 until_at:=intent.starts_at+make_interval(secs=>intent.duration_seconds+intent.buffer_seconds);
 if intent.id is null or children<1 or not settings.finale_available or intent.portal_id<>settings.final_portal_id
  or intent.starts_at>app_private.schedule_latest_finale_arrival(r.schedule_revision_id)
  or not exists(select 1 from app_private.portal_effective_windows(intent.portal_id)w where w.is_finale and intent.starts_at>=w.opens_at and intent.starts_at<=w.arrival_closes_at
   and intent.duration_seconds=w.visit_seconds and intent.buffer_seconds=w.buffer_seconds and until_at<=w.closes_at)
  or not app_private.portal_interval_available(intent.portal_id,g.id,intent.starts_at,until_at,children,_at)
  or exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id
   where rp.run_id=r.id and rp.attendance='present'and rp.departed_at is null and app_private.child_step_free_requirement(rc.child_id)is distinct from false
    and app_private.portal_accessibility_status(intent.portal_id)<>'step_free')then return null;end if;
 select * into existing from app_private.portal_reservations p where p.run_id=r.id and p.kind='finale'and p.status in('held','active')
  and p.portal_id=intent.portal_id and p.reserved_from=intent.starts_at and p.reserved_until=until_at order by p.created_at desc,p.id desc limit 1;
 if existing.id is not null then
  if existing.child_count<>children then update app_private.portal_reservations set child_count=children,version=version+1 where id=existing.id;end if;
  return existing.id;
 end if;
 update app_private.portal_reservations set status='cancelled',cancelled_reason='Expliciet beoordeelde finale-afspraak',version=version+1 where run_id=r.id and kind='finale'and status='held';
 insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count,expires_at)
 values(g.event_id,intent.portal_id,g.id,r.id,'finale','held',intent.starts_at,until_at,children,settings.finale_closes_at)returning id into rid;
 return rid;
end $$;

alter function app_private.dispatch_next_stop(uuid,timestamptz,boolean,uuid)rename to dispatch_next_stop_before_joint_routes;
revoke all on function app_private.dispatch_next_stop_before_joint_routes(uuid,timestamptz,boolean,uuid)from public,anon,authenticated;
create function app_private.dispatch_next_stop(_run_id uuid,_decision_at timestamptz default clock_timestamp(),_force_finale boolean default false,_preferred_portal_id uuid default null)returns jsonb
language plpgsql security definer set search_path=''as $$
declare r app_private.group_runs;g app_private.walking_groups;p app_private.live_route_plans;intent app_private.live_route_visits;finale app_private.live_route_visits;
 settings app_private.event_route_settings;source jsonb;point jsonb;travel record;exit_leg record;arrival timestamptz;departure timestamptz;physical_end timestamptz;
 children integer;requested integer;visited integer;next_sequence integer;decision_number integer;reservation_id uuid;finale_reservation uuid;stop_id uuid;cutover timestamptz;force_finale boolean:=_force_finale;
begin
 select * into r from app_private.group_runs where id=_run_id;
 select * into g from app_private.walking_groups where id=r.group_id;
 if r.id is null or r.status<>'live'or r.current_stop_id is not null then raise exception 'RUN_NOT_DISPATCHABLE'using errcode='23514';end if;
 perform 1 from app_private.events where id=g.event_id for no key update;
 perform pg_advisory_xact_lock(hashtextextended(g.event_id::text||':route-dispatch',0));
 select * into r from app_private.group_runs where id=_run_id for update;
 select * into p from app_private.live_route_plans where group_id=g.id;
 if r.accepted_route_version_id is null and p.accepted_version_id is null then
  select activated_at into cutover from app_private.joint_route_policy_releases where policy_version='joint-reception-v1';
  if coalesce(r.started_at,r.created_at)<cutover or(r.active_plan_version_id is not null and not exists(select 1 from app_private.live_route_visits v where v.group_id=g.id and v.kind<>'start'and v.retired_at is null))then
   return app_private.dispatch_next_stop_before_joint_routes(_run_id,_decision_at,_force_finale,_preferred_portal_id);end if;
  raise exception 'JOINT_ROUTE_REVIEW_REQUIRED'using errcode='23514',detail='Bereken, beoordeel en sla via Avondregie eerst een gezamenlijk routevoorstel op. De bestaande startafspraak is behouden.';
 end if;
 if r.accepted_route_version_id is null then
  if not app_private.canonical_route_group_current(g.id)then raise exception 'ACCEPTED_ROUTE_STALE'using errcode='40001';end if;
  update app_private.group_runs set accepted_route_version_id=p.accepted_version_id,version=version+1 where id=r.id returning * into r;
 end if;
 select * into settings from app_private.event_route_settings where event_id=g.event_id;
 select count(*)into children from app_private.run_participants where run_id=r.id and attendance='present'and departed_at is null;
 if children=0 then raise exception 'RUN_EMPTY'using errcode='23514';end if;
 select count(*)into visited from app_private.run_stops where run_id=r.id and stop_kind='ordinary'and state='completed'and outcome in('visited','mixed');
 requested:=g.desired_ordinary_visits;if requested is not null and visited>=requested then force_finale:=true;end if;
 select * into intent from app_private.live_route_visits v where v.group_id=g.id and v.retired_at is null and v.kind<>'start'and v.run_stop_id is null
  and(not force_finale or v.kind='finale')order by v.sequence limit 1 for update;
 if intent.id is null then
  update app_private.group_runs set status='completed',finished_at=clock_timestamp(),version=version+1 where id=r.id;
  update app_private.walking_groups set status='completed',version=version+1 where id=g.id;
  return jsonb_build_object('decision','completed');end if;
 if _preferred_portal_id is not null and _preferred_portal_id<>intent.portal_id then raise exception 'CANONICAL_ROUTE_INTENT_CONFLICT'using errcode='23514';end if;
 select app_private.portal_location(coalesce(s.portal_id,planned.portal_id))into source from app_private.run_stops s left join app_private.route_plan_stops planned on planned.id=s.plan_stop_id
  where s.run_id=r.id and s.state='completed'order by s.sequence desc limit 1;
 if source is null then
  select pub.point_snapshot into point from app_private.group_start_publications pub where pub.group_id=g.id and pub.schedule_id is not distinct from r.schedule_revision_id order by pub.publication_order desc limit 1;
  if point is null then point:=app_private.route_group_start_context(g.id)->'pointSnapshot';end if;
  source:=app_private.routing_position((point->>'marker_latitude')::numeric,(point->>'marker_longitude')::numeric,(point->>'geocoded_latitude')::numeric,(point->>'geocoded_longitude')::numeric,(point->>'latitude')::numeric,(point->>'longitude')::numeric);
 end if;
 select * into travel from app_private.destination_estimate((source->>'latitude')::numeric,(source->>'longitude')::numeric,
  (app_private.portal_location(intent.portal_id)->>'latitude')::numeric,(app_private.portal_location(intent.portal_id)->>'longitude')::numeric);
 if travel.duration_seconds is null then raise exception 'CANONICAL_ROUTE_LOCATION_UNAVAILABLE'using errcode='23514';end if;
 finale_reservation:=app_private.canonical_reserve_finale(r.id,_decision_at);
 if finale_reservation is null then return jsonb_build_object('decision','wait','retryAfterSeconds',120,'finaleFull',true,'requiresReplanning',true);end if;
 departure:=intent.starts_at-make_interval(secs=>travel.duration_seconds::integer);
 if _decision_at<departure then return jsonb_build_object('decision','wait','retryAfterSeconds',greatest(1,ceil(extract(epoch from departure-_decision_at)))::integer,'plannedPortalId',intent.portal_id,'acceptedVersionId',r.accepted_route_version_id);end if;
 arrival:=_decision_at+make_interval(secs=>travel.duration_seconds::integer);physical_end:=arrival+make_interval(secs=>intent.duration_seconds+intent.buffer_seconds);
 select * into finale from app_private.live_route_visits where group_id=g.id and kind='finale'and retired_at is null order by sequence limit 1;
 select * into exit_leg from app_private.destination_estimate((app_private.portal_location(intent.portal_id)->>'latitude')::numeric,(app_private.portal_location(intent.portal_id)->>'longitude')::numeric,
  (app_private.portal_location(finale.portal_id)->>'latitude')::numeric,(app_private.portal_location(finale.portal_id)->>'longitude')::numeric);
 if(intent.kind='ordinary'and(arrival+make_interval(secs=>intent.duration_seconds)>app_private.group_ordinary_deadline(g.id)
   or exit_leg.duration_seconds is null or arrival+make_interval(secs=>intent.duration_seconds+exit_leg.duration_seconds::integer)>finale.starts_at))
  or(intent.kind='finale'and arrival>intent.starts_at)
  or not exists(select 1 from app_private.portals portal cross join lateral app_private.portal_effective_windows(portal.id)w
   where portal.id=intent.portal_id and portal.approval_status='approved'and portal.lifecycle_status='active'and portal.operation_status in('open','scheduled')
    and arrival>=w.opens_at and case when w.is_finale then arrival<=w.arrival_closes_at else arrival<w.arrival_closes_at end
    and intent.duration_seconds=w.visit_seconds and intent.buffer_seconds=w.buffer_seconds and physical_end<=w.closes_at)
  or not app_private.portal_interval_available(intent.portal_id,g.id,arrival,physical_end,children,_decision_at)
  or exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id
   where rp.run_id=r.id and rp.attendance='present'and rp.departed_at is null and app_private.child_step_free_requirement(rc.child_id)is distinct from false
    and app_private.portal_accessibility_status(intent.portal_id)<>'step_free')then
  insert into app_private.route_alerts(event_id,group_id,run_id,portal_id,priority,code,message)
   select g.event_id,g.id,r.id,intent.portal_id,'warning','CANONICAL_ROUTE_RECHECK','De beoordeelde route past niet meer in de actuele ontvangst of vaste finale-afspraak. Controleer een expliciete herplanning.'
   where not exists(select 1 from app_private.route_alerts where run_id=r.id and code='CANONICAL_ROUTE_RECHECK'and status='open');
  return jsonb_build_object('decision','wait','retryAfterSeconds',120,'requiresReplanning',true,'reason','CANONICAL_ROUTE_RECHECK','acceptedVersionId',r.accepted_route_version_id);end if;

 if intent.kind='finale'then
  reservation_id:=finale_reservation;update app_private.portal_reservations set status='active',version=version+1 where id=reservation_id;
 else
  insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count,expires_at)
  values(g.event_id,intent.portal_id,g.id,r.id,'ordinary','active',arrival,physical_end,children,greatest(physical_end,_decision_at+make_interval(secs=>settings.reservation_ttl_seconds)))returning id into reservation_id;
 end if;
 select coalesce(max(sequence),0)+1 into next_sequence from app_private.run_stops where run_id=r.id;
 insert into app_private.run_stops(run_id,portal_id,reservation_id,stop_kind,sequence,state,opened_at)
 values(r.id,intent.portal_id,reservation_id,intent.kind::app_private.dynamic_stop_kind,next_sequence,'active',_decision_at)returning id into stop_id;
 insert into app_private.stop_participant_statuses(run_stop_id,run_participant_id)
 select stop_id,id from app_private.run_participants where run_id=r.id and attendance='present'and departed_at is null;
 update app_private.group_runs set current_stop_id=stop_id,version=version+1 where id=r.id;
 select coalesce(max(sequence),0)+1 into decision_number from app_private.dispatch_decisions where run_id=r.id;
 insert into app_private.dispatch_decisions(event_id,run_id,sequence,selected_portal_id,selected_kind,decision,input_snapshot,candidate_summary,reason)
 values(g.event_id,r.id,decision_number,intent.portal_id,intent.kind::app_private.dynamic_stop_kind,intent.kind,
  jsonb_build_object('decidedAt',_decision_at,'acceptedVersionId',r.accepted_route_version_id,'plannedArrivalAt',intent.starts_at,'expectedArrivalAt',arrival,'walkSeconds',travel.duration_seconds),'[]','Expliciet beoordeelde route en vaste finale-afspraak');
 insert into app_private.journey_events(run_id,stop_id,event_type,safe_metadata)values(r.id,stop_id,'stop.dispatched',jsonb_build_object('kind',intent.kind,'portalId',intent.portal_id,'acceptedVersionId',r.accepted_route_version_id));
 return jsonb_build_object('decision',intent.kind,'stopId',stop_id,'portalId',intent.portal_id,'acceptedVersionId',r.accepted_route_version_id);
end $$;
revoke all on function app_private.canonical_reserve_finale(uuid,timestamptz),app_private.dispatch_next_stop(uuid,timestamptz,boolean,uuid)from public,anon,authenticated;

-- Every existing publication entry point delegates to this protected primitive.
-- Empty legacy boards keep their established static publication workflow.
alter function app_private.publish_startregie_ops(text,uuid[],text)rename to publish_startregie_ops_before_joint_routes;
revoke all on function app_private.publish_startregie_ops_before_joint_routes(text,uuid[],text)from public,anon,authenticated;
create function app_private.publish_startregie_ops(_event_slug text,_schedule_ids uuid[],_reason text)returns jsonb
language plpgsql security definer set search_path=''as $$
declare eid uuid;schedule record;source text;
begin
 select id into eid from app_private.events where slug=_event_slug for no key update;
 if eid is null or auth.uid()is null or not(app_private.has_capability(eid,'groups_manage',auth.uid())or app_private.has_capability(eid,'event_admin',auth.uid()))then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(eid::text||':route-dispatch',0));source:=app_private.joint_route_source_hash(eid);
 for schedule in select s.*from app_private.group_schedule_revisions s where s.id=any(_schedule_ids)and exists(select 1 from app_private.walking_groups g where g.id=s.group_id and g.event_id=eid)loop
  -- A separately confirmed replacement follows the established atomic start
  -- correction flow. Its new semantic source hash invalidates the old route;
  -- it never recalculates or starts that route. Requiring the replacement to
  -- match the still-authoritative old publication would deadlock this flow.
  if exists(select 1 from app_private.current_start_publication(schedule.group_id) published
   where published.schedule_id is distinct from schedule.id) then continue;end if;
  if exists(select 1 from app_private.live_route_visits v where v.group_id=schedule.group_id and v.kind<>'start'and v.retired_at is null)
   and(not app_private.canonical_route_group_current(schedule.group_id,source)or(app_private.route_group_start_context(schedule.group_id)->>'scheduleId')::uuid is distinct from schedule.id)then
   raise exception 'JOINT_ROUTE_REVIEW_REQUIRED'using errcode='23514',detail='Bereken, beoordeel en sla eerst het gezamenlijke routevoorstel voor de te publiceren afspraak op.';end if;
 end loop;
 return app_private.publish_startregie_ops_before_joint_routes(_event_slug,_schedule_ids,_reason);
end $$;
revoke all on function app_private.publish_startregie_ops(text,uuid[],text)from public,anon,authenticated;

-- A manual change is itself an explicit, reason-bearing review. Preserve its
-- existing command/undo/publication semantics, and record a new immutable route
-- version only after all physical warnings for that group pass.
create function app_private.accept_manual_route_intention(_event uuid,_group uuid,_reason text)returns jsonb
language plpgsql security definer set search_path=''as $$
declare plan jsonb;plans jsonb;source text;board text;digest text;version app_private.joint_route_plan_versions;notice jsonb;ctx jsonb;
 position jsonb;visit jsonb;travel record;visits jsonb:='[]'::jsonb;
begin
 ctx:=app_private.route_group_start_context(_group);
 select n into notice from jsonb_array_elements(app_private.live_planboard_warnings(_event,'[]'))n
  where n->>'severity'='block'and n->'groupIds'@>jsonb_build_array(_group)limit 1;
 if notice is not null then raise exception 'PLANBOARD_DOMAIN_BLOCKED'using errcode='23514',detail=notice::text;end if;
 select jsonb_build_object('groupId',_group,'startsAt',ctx->'startsAt',
  'finaleArrivalAt',finale.starts_at,'expectedCompletionAt',finale.starts_at+make_interval(secs=>finale.duration_seconds),'diagnostics','[]'::jsonb,
  'visits',coalesce((select jsonb_agg(jsonb_build_object('portalId',v.portal_id,'kind',v.kind,'sequence',v.sequence,
   'startsAt',v.starts_at,'visitSeconds',v.duration_seconds,'bufferSeconds',v.buffer_seconds,'walkSeconds',0,'walkMeters',0)order by v.sequence)
   from(select actual.*,row_number()over(order by sequence)::integer canonical_sequence from app_private.live_route_visits actual where actual.group_id=_group and actual.retired_at is null and actual.kind<>'start')v),'[]'))into plan
 from app_private.live_route_visits finale where finale.group_id=_group and finale.retired_at is null and finale.kind='finale'order by finale.sequence limit 1;
 if plan is null then raise exception 'FINALE_REQUIRED'using errcode='23514';end if;
 -- Normalize sequence after a purely administrative start marker.
 plan:=jsonb_set(plan,'{visits}',(select jsonb_agg(v||jsonb_build_object('sequence',n)order by n)from jsonb_array_elements(plan->'visits')with ordinality q(v,n)));
 position:=app_private.routing_position((ctx#>>'{pointSnapshot,marker_latitude}')::numeric,(ctx#>>'{pointSnapshot,marker_longitude}')::numeric,
  (ctx#>>'{pointSnapshot,geocoded_latitude}')::numeric,(ctx#>>'{pointSnapshot,geocoded_longitude}')::numeric,
  (ctx#>>'{pointSnapshot,latitude}')::numeric,(ctx#>>'{pointSnapshot,longitude}')::numeric);
 for visit in select *from jsonb_array_elements(plan->'visits')order by(value->>'sequence')::integer loop
  select *into travel from app_private.destination_estimate((position->>'latitude')::numeric,(position->>'longitude')::numeric,
   (app_private.portal_location((visit->>'portalId')::uuid)->>'latitude')::numeric,(app_private.portal_location((visit->>'portalId')::uuid)->>'longitude')::numeric);
  if travel.duration_seconds is null then raise exception 'CANONICAL_ROUTE_LOCATION_UNAVAILABLE'using errcode='23514';end if;
  visits:=visits||jsonb_build_array(visit||jsonb_build_object('walkSeconds',travel.duration_seconds,'walkMeters',travel.distance_m));
  position:=app_private.portal_location((visit->>'portalId')::uuid);
 end loop;
 plan:=jsonb_set(plan,'{visits}',visits);
 if coalesce((ctx#>>'{pointSnapshot,counts_as_first_portal_visit}')::boolean,false)and ctx#>>'{pointSnapshot,linked_portal_id}'is distinct from(plan->'visits'->0->>'portalId')then
  plan:=jsonb_set(plan,'{diagnostics}','[{"code":"FIRST_PORTAL_ALTERNATIVE","severity":"warning","message":"De expliciet opgeslagen route gebruikt een ander werkelijk eerste bezoek; verzamelplek en starttijd blijven behouden."}]'::jsonb);
 end if;
 plans:=jsonb_build_array(plan);source:=app_private.joint_route_source_hash(_event);board:=app_private.live_planboard_hash(_event);digest:=app_private.joint_route_proposal_hash(source,board,plans);
 insert into app_private.joint_route_plan_versions(event_id,revision,source_hash,plan_hash,board_hash,policy_version,accepted_by,group_plans,reason)
 select _event,coalesce(max(revision),0)+1,source,digest,board,'joint-reception-v1',auth.uid(),plans,trim(_reason)from app_private.joint_route_plan_versions where event_id=_event returning *into version;
 update app_private.live_route_plans set accepted_version_id=version.id,source_hash=source,plan_hash=digest,schedule_id=(ctx->>'scheduleId')::uuid,version=live_route_plans.version+1 where group_id=_group;
 -- This runs only after the administrator explicitly saved this manual edit.
 update app_private.group_runs set accepted_route_version_id=version.id,version=group_runs.version+1 where group_id=_group and status in('live','paused')and accepted_route_version_id is not null;
 return jsonb_build_object('acceptedVersionId',version.id,'revision',version.revision,'proposalHash',digest,'sourceHash',source);
end $$;

-- Following visits can move; a protected reserved finale never slides with them.
create or replace function api.admin_live_planboard_preview(_event_slug text,_command jsonb,_input_hash text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare e app_private.events; v app_private.live_route_visits; changes jsonb; before_rows jsonb; warnings jsonb; delta interval; at_time timestamptz; target uuid; duration integer; saved app_private.command_receipts;
 changes_start boolean:=false; protected boolean:=false; point uuid; g app_private.walking_groups; publication app_private.group_start_publications; affected uuid[];
begin
 select * into e from app_private.events where slug=_event_slug;
 if auth.uid() is null or e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _input_hash is distinct from app_private.live_planboard_hash(e.id) then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if _command->>'action' in ('undo','redo') then
  select * into saved from app_private.command_receipts where actor_id=auth.uid() and command_type='planboard.apply' and idempotency_key=_command->>'restoreKey';
  if saved.id is null or saved.safe_result->>'eventId'<>e.id::text then raise exception 'INVALID_UNDO'; end if;
  changes:=case when _command->>'action'='undo' then saved.safe_result->'before' else saved.safe_result->'after' end;
  before_rows:=case when _command->>'action'='undo' then saved.safe_result->'after' else saved.safe_result->'before' end;
  if exists(select 1 from jsonb_array_elements(before_rows) old left join app_private.live_route_visits current on current.id=(old->>'id')::uuid
   where current.id is null or current.run_stop_id is not null or current.retired_at is not null or current.portal_id is distinct from (old->>'portalId')::uuid or current.starts_at is distinct from (old->>'startsAt')::timestamptz or current.duration_seconds is distinct from (old->>'durationSeconds')::integer) then raise exception 'STALE_REVISION' using errcode='40001'; end if;
  select * into v from app_private.live_route_visits where id=(changes->0->>'id')::uuid;
 elsif _command->>'action'='move' then
  select * into v from app_private.live_route_visits where id=(_command->>'visitId')::uuid and event_id=e.id;
  if v.id is null or v.run_stop_id is not null or v.retired_at is not null or v.kind='finale' then raise exception 'VISIT_PROTECTED' using errcode='23514'; end if;
  at_time:=app_private.parse_amsterdam_instant(_command->>'startsAt');target:=(_command->>'portalId')::uuid;duration:=coalesce((_command->>'durationSeconds')::integer,v.duration_seconds);
  if at_time is null or extract(minute from at_time at time zone 'Europe/Amsterdam')::integer%10<>0 or extract(second from at_time)<>0 or duration not between 30 and 7200 then raise exception 'INVALID_SNAP_OR_DURATION' using errcode='22023'; end if;
  delta:=at_time-v.starts_at;
  select jsonb_agg(jsonb_build_object('id',other.id,'groupId',other.group_id,'portalId',case when other.id=v.id then target else other.portal_id end,
   'startsAt',other.starts_at+delta,'durationSeconds',case when other.id=v.id then duration else other.duration_seconds end,
   'bufferSeconds',case when other.id=v.id then greatest(other.buffer_seconds,coalesce((select min(w.buffer_minutes)*60 from app_private.portal_windows w where w.portal_id=target and at_time>=w.opens_at and at_time<w.closes_at),other.buffer_seconds)) else other.buffer_seconds end,'source','manual') order by other.sequence) into changes
  from app_private.live_route_visits other where other.group_id=v.group_id and other.run_stop_id is null and other.retired_at is null
   and (other.id=v.id or (coalesce((_command->>'shiftFollowing')::boolean,false) and other.sequence>v.sequence and other.kind<>'finale'));
 else raise exception 'INVALID_INPUT' using errcode='22023'; end if;
 if changes is null or jsonb_array_length(changes)=0 then raise exception 'INVALID_INPUT'; end if;
 select * into g from app_private.walking_groups where id=v.group_id and retired_at is null;
 if g.route_mode='legacy' and (g.current_schedule_revision_id is null or exists(select 1 from app_private.group_runs legacy where legacy.group_id=g.id and legacy.active_plan_version_id is not null)) then raise exception 'USE_LEGACY_EVENING_REGIE' using errcode='23514'; end if;
 if g.id is null or exists(select 1 from app_private.group_runs where group_id=g.id and status in ('completed','stopped')) then raise exception 'GROUP_FINISHED' using errcode='23514'; end if;
 select * into publication from app_private.current_start_publication(g.id);
 changes_start:=v.sequence=1 and not exists(select 1 from app_private.group_runs where group_id=g.id)
 and exists(select 1 from app_private.group_schedule_revisions s join app_private.start_slots slot on slot.id=s.start_slot_id join app_private.start_points p on p.id=slot.start_point_id where s.id=g.current_schedule_revision_id and (v.kind='start' or p.counts_as_first_portal_visit) and p.linked_portal_id=v.portal_id);
 if changes_start then
  select id into point from app_private.start_points where event_id=e.id and active and linked_portal_id=(changes->0->>'portalId')::uuid and counts_as_first_portal_visit=(v.kind<>'start') order by id limit 1;
  if point is null then raise exception 'CHOOSE_A_CONFIRMED_LINKED_START_POINT' using errcode='23514'; end if;
  if not app_private.departure_time_in_window(e.id,(changes->0->>'startsAt')::timestamptz)then
   raise exception 'START_TIME_OUTSIDE_EVENT'using errcode='23514';end if;
  if not app_private.start_point_ready_at(point,(changes->0->>'startsAt')::timestamptz)then
   raise exception 'START_POINT_CLOSED'using errcode='23514';end if;
  protected:=publication.id is not null or app_private.is_start_confirmation_current(g.current_schedule_revision_id);
 end if;
 select array_agg((c->>'id')::uuid) into affected from jsonb_array_elements(changes) c;
 warnings:=coalesce((select jsonb_agg(w) from jsonb_array_elements(app_private.live_planboard_warnings(e.id,changes)) w where not(changes_start and w->>'code'='START_APPOINTMENT_CHANGED')and exists(select 1 from jsonb_array_elements_text(w->'visitIds') vid where vid::uuid=any(affected))),'[]'::jsonb);
 select jsonb_agg(jsonb_build_object('id',x.id,'groupId',x.group_id,'portalId',x.portal_id,'startsAt',x.starts_at,'durationSeconds',x.duration_seconds,'bufferSeconds',x.buffer_seconds,'source',x.source) order by x.sequence) into before_rows
 from app_private.live_route_visits x where x.id=any(affected);
 return jsonb_build_object('eventId',e.id,'inputHash',_input_hash,'groupId',g.id,'groupCode',g.system_code,'before',before_rows,'changes',changes,'warnings',warnings,
  'changesStart',changes_start,'startPointId',point,'requiresConfirmation',protected,'publishedStartsAt',publication.starts_at,
  'recipients',(select count(*) from app_private.group_adult_recipients(g.id)),
  'communication',case when changes_start then 'Nieuw concept; bestaande publicatie blijft geldig. Er wordt nog geen starttijdmail klaargezet.' else 'Route-intentie voor de avondregie; geen starttijdmail.' end);
end $$;
alter function api.admin_live_planboard_apply(text,jsonb,text,boolean,text,text)rename to admin_live_planboard_apply_before_canonical_routes;
revoke all on function api.admin_live_planboard_apply_before_canonical_routes(text,jsonb,text,boolean,text,text)from public,anon,authenticated;
create function api.admin_live_planboard_apply(_event_slug text,_command jsonb,_input_hash text,_confirmed boolean,_reason text,_idempotency_key text)returns jsonb
language plpgsql security definer set search_path=''as $$
declare eid uuid;result jsonb;replay boolean;metadata jsonb;gid uuid;preview jsonb;
begin
 select id into eid from app_private.events where slug=_event_slug for no key update;
 if eid is null or auth.uid()is null or not app_private.has_capability(eid,'groups_manage',auth.uid())then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(eid::text||':route-dispatch',0));
 select exists(select 1 from app_private.command_receipts where actor_id=auth.uid()and command_type='planboard.apply'and idempotency_key=_idempotency_key)into replay;
 if not replay then preview:=api.admin_live_planboard_preview(_event_slug,_command,_input_hash);gid:=(preview->>'groupId')::uuid;end if;
 result:=api.admin_live_planboard_apply_before_canonical_routes(_event_slug,_command,_input_hash,_confirmed,_reason,_idempotency_key);
 if not replay and not coalesce((preview->>'changesStart')::boolean,false)then
  metadata:=app_private.accept_manual_route_intention(eid,gid,_reason);result:=result||metadata||jsonb_build_object('inputHash',app_private.live_planboard_hash(eid));
  update app_private.command_receipts set safe_result=result where actor_id=auth.uid()and command_type='planboard.apply'and idempotency_key=_idempotency_key;
 end if;
 return result;
end $$;
revoke all on function api.admin_live_planboard_apply(text,jsonb,text,boolean,text,text),api.admin_live_planboard_preview(text,jsonb,text)from public,anon;
grant execute on function api.admin_live_planboard_apply(text,jsonb,text,boolean,text,text),api.admin_live_planboard_preview(text,jsonb,text)to authenticated;
revoke all on function app_private.accept_manual_route_intention(uuid,uuid,text)from public,anon,authenticated;

-- Background cutoff uses the actual hard ordinary boundary for a new accepted
-- route; existing unbound journeys retain their original behavior.
create or replace function api.worker_dispatch_due_groups(_event_slug text, _batch_size integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_id uuid;
  candidate record;
  dispatched integer := 0;
  alerted integer := 0;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  for candidate in
    select run.id, run.group_id, run.current_stop_id, run.updated_at, case when run.accepted_route_version_id is not null then app_private.group_ordinary_deadline(run.group_id) else schedule.effective_ordinary_stop_at end as effective_ordinary_stop_at,
      stop.stop_kind, stop.opened_at, stop.reservation_id, reservation.expires_at as reservation_expires_at
    from app_private.group_runs run
    join app_private.walking_groups walking_group on walking_group.id = run.group_id and walking_group.route_mode = 'dynamic'
    join app_private.group_schedule_revisions schedule on schedule.id = run.schedule_revision_id
    left join app_private.run_stops stop on stop.id = run.current_stop_id
    left join app_private.portal_reservations reservation on reservation.id = stop.reservation_id
    where walking_group.event_id = v_event_id and run.status = 'live'
    order by run.updated_at
    for update of run skip locked
    limit least(greatest(_batch_size, 1), 200)
  loop
    if candidate.current_stop_id is null then
      perform app_private.dispatch_next_stop(candidate.id, clock_timestamp());
      dispatched := dispatched + 1;
    elsif candidate.stop_kind = 'ordinary' and candidate.effective_ordinary_stop_at <= clock_timestamp() then
      if exists (select 1 from app_private.scan_evidence evidence where evidence.run_stop_id = candidate.current_stop_id) then
        insert into app_private.route_alerts(event_id, group_id, run_id, priority, code, message)
        select v_event_id, candidate.group_id, candidate.id, 'warning', 'ACTIVE_VISIT_AFTER_STOP',
          'De stopgrens is bereikt tijdens een lopend bezoek; rond veilig af en ga daarna naar de eindpoort.'
        where not exists (select 1 from app_private.route_alerts where run_id = candidate.id and status = 'open' and code = 'ACTIVE_VISIT_AFTER_STOP');
        alerted := alerted + 1;
      else
        update app_private.run_stops set state = 'completed', outcome = 'system_skipped',
          completed_at = clock_timestamp(), completion_reason = 'Stopgrens bereikt zonder bevestigde scan', version = version + 1
        where id = candidate.current_stop_id and state = 'active';
        update app_private.stop_participant_statuses set status = 'skipped', required_for_completion = false,
          exclusion_reason = 'Stopgrens bereikt zonder bevestigde scan', reason = 'Automatische overgang naar laatste poort',
          decided_at = clock_timestamp(), version = version + 1
        where run_stop_id = candidate.current_stop_id and status = 'pending';
        update app_private.portal_reservations set status = 'cancelled',
          cancelled_reason = 'Stopgrens bereikt zonder bevestigde scan', version = version + 1
        where id = candidate.reservation_id and status in ('held', 'active');
        update app_private.group_runs set current_stop_id = null, version = version + 1 where id = candidate.id;
        insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
        values (candidate.id, candidate.current_stop_id, 'stop.cutoff_redirected', jsonb_build_object('reason', 'Stopgrens bereikt zonder bevestigde scan'));
        perform app_private.dispatch_next_stop(candidate.id, clock_timestamp(), true, null);
        dispatched := dispatched + 1;
      end if;
    elsif candidate.stop_kind = 'ordinary'
      and candidate.reservation_expires_at <= clock_timestamp()
      and not exists (select 1 from app_private.scan_evidence evidence where evidence.run_stop_id = candidate.current_stop_id) then
      update app_private.run_stops set state = 'completed', outcome = 'system_skipped',
        completed_at = clock_timestamp(), completion_reason = 'Aankomstvenster verlopen zonder bevestigde scan', version = version + 1
      where id = candidate.current_stop_id and state = 'active';
      update app_private.stop_participant_statuses set status = 'skipped', required_for_completion = false,
        exclusion_reason = 'Aankomstvenster verlopen zonder bevestigde scan', reason = 'Automatische herplanning naar een veilige actuele bestemming',
        decided_at = clock_timestamp(), version = version + 1
      where run_stop_id = candidate.current_stop_id and status = 'pending';
      update app_private.portal_reservations set status = 'expired', version = version + 1
      where id = candidate.reservation_id and status in ('held', 'active');
      update app_private.group_runs set current_stop_id = null, version = version + 1 where id = candidate.id;
      insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
      values (candidate.id, candidate.current_stop_id, 'stop.reservation_expired',
        jsonb_build_object('reason', 'Aankomstvenster verlopen zonder bevestigde scan'));
      insert into app_private.route_alerts(event_id, group_id, run_id, priority, code, message)
      values (v_event_id, candidate.group_id, candidate.id, 'warning', 'DESTINATION_EXPIRED_REPLANNED',
        'De vorige aankomstreservering verliep zonder scan; de groep kreeg een nieuwe veilige serverbestemming.');
      perform app_private.dispatch_next_stop(candidate.id, clock_timestamp());
      dispatched := dispatched + 1;
    end if;
    if candidate.updated_at < clock_timestamp() - interval '10 minutes' then
      insert into app_private.route_alerts(event_id, group_id, run_id, priority, code, message)
      select v_event_id, candidate.group_id, candidate.id, 'warning', 'STALE_GROUP_CONNECTION',
        'De groep heeft langer dan tien minuten geen serverbevestiging gegeven.'
      where not exists (select 1 from app_private.route_alerts where run_id = candidate.id and status = 'open' and code = 'STALE_GROUP_CONNECTION');
      alerted := alerted + 1;
    end if;
  end loop;
  return jsonb_build_object('dispatched', dispatched, 'alerts', alerted);
end;
$$;

alter function api.group_snapshot(uuid)rename to group_snapshot_before_canonical_timing;
revoke all on function api.group_snapshot_before_canonical_timing(uuid)from public,anon,authenticated;
create function api.group_snapshot(_group_id uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare result jsonb;finale app_private.live_route_visits;ordinary_end timestamptz;pub app_private.group_start_publications;
begin
 result:=api.group_snapshot_before_canonical_timing(_group_id);
 select *into pub from app_private.current_start_publication(_group_id);
 if(pub.id is not null or exists(select 1 from app_private.group_runs r where r.group_id=_group_id and r.accepted_route_version_id is not null))
  and exists(select 1 from app_private.live_route_plans p where p.group_id=_group_id and p.accepted_version_id is not null)then
  select *into finale from app_private.live_route_visits where group_id=_group_id and retired_at is null and kind='finale'order by sequence limit 1;
  select max(starts_at+make_interval(secs=>duration_seconds))into ordinary_end from app_private.live_route_visits where group_id=_group_id and retired_at is null and kind='ordinary';
  result:=jsonb_set(result,'{group,timing}',coalesce(result#>'{group,timing}','{}')||jsonb_build_object('ordinaryStopAt',app_private.group_ordinary_deadline(_group_id),'ordinaryEndsAt',ordinary_end,
   'expectedFinaleArrivalAt',finale.starts_at,'expectedCompletionAt',finale.starts_at+make_interval(secs=>finale.duration_seconds),
   'physicalFinaleEndsAt',finale.starts_at+make_interval(secs=>finale.duration_seconds+finale.buffer_seconds)));
 end if;
 return result;
end $$;
revoke all on function api.group_snapshot(uuid)from public,anon;
grant execute on function api.group_snapshot(uuid)to authenticated;

-- Existing start-slot optimization receives the same physical finale policy.
-- Configured Kaders fields remain editable as stored; effective limits are
-- additional metadata and cannot silently extend or replace a hard window.
alter function api.admin_startregie_snapshot(text)rename to admin_startregie_snapshot_before_shared_finale;
revoke all on function api.admin_startregie_snapshot_before_shared_finale(text)from public,anon,authenticated;
create function api.admin_startregie_snapshot(_event_slug text)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare result jsonb;eid uuid;pid uuid;policy jsonb;
begin
 result:=api.admin_startregie_snapshot_before_shared_finale(_event_slug);
 select e.id,s.final_portal_id into eid,pid from app_private.events e left join app_private.event_route_settings s on s.event_id=e.id where e.slug=_event_slug;
 select jsonb_build_object('finaleHeadwaySeconds',coalesce(max(w.headway_seconds),(select max(p.arrival_headway_seconds)from app_private.portals p where app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(pid))),
  'finaleEffectiveOpensAt',min(w.opens_at),'finaleEffectiveLastArrivalAt',max(w.arrival_closes_at),'finaleEffectiveClosesAt',max(w.closes_at),
  'finaleWindows',coalesce(jsonb_agg(jsonb_build_object('opensAt',w.opens_at,'arrivalClosesAt',w.arrival_closes_at,'closesAt',w.closes_at,
   'maxGroups',w.max_groups,'maxChildren',w.max_children,'maxTotalChildren',w.max_total_children)order by w.opens_at,w.closes_at),'[]'))into policy
 from app_private.portal_effective_windows(pid)w;
 result:=jsonb_set(result,'{settings}',coalesce(result->'settings','{}')||policy);
 return jsonb_set(result,'{startPoints}',coalesce((select jsonb_agg(point||jsonb_build_object('physicalDepartureKey',app_private.start_departure_key((point->>'id')::uuid)))from jsonb_array_elements(result->'startPoints')point),'[]'::jsonb));
end $$;
revoke all on function api.admin_startregie_snapshot(text)from public,anon;
grant execute on function api.admin_startregie_snapshot(text)to authenticated;
