-- Exact, authorized household changes; no reopening, republishing, or route rewrite.
set lock_timeout='5s';

create table app_private.registration_management_changes (
 id uuid primary key,event_id uuid not null references app_private.events(id),
 registration_id uuid not null references app_private.registrations(id),
 action text not null check(action in ('edit_children','move')),actor_id uuid not null references auth.users(id),
 source_group_id uuid references app_private.walking_groups(id),target_group_id uuid references app_private.walking_groups(id),
 group_registration_id uuid references app_private.group_registrations(id),target_schedule_id uuid references app_private.group_schedule_revisions(id),
 registration_version integer not null,created_at timestamptz not null default clock_timestamp()
);
create index registration_management_latest_move on app_private.registration_management_changes(registration_id,created_at desc,id desc) where action='move';
alter table app_private.registration_management_changes enable row level security;
revoke all on app_private.registration_management_changes from public,anon,authenticated;

-- Never trust a client-writable GUC. Only revoked server helpers can create
-- this exact transaction/backend/actor/household scope, and successful commands remove it.
create table app_private.registration_management_scopes (
 transaction_id bigint not null,backend_pid integer not null,command_id uuid not null,
 event_id uuid not null references app_private.events(id),registration_id uuid not null references app_private.registrations(id),
 actor_id uuid not null references auth.users(id),group_ids uuid[] not null,before_groups jsonb not null,
 primary key(transaction_id,backend_pid,command_id)
);
alter table app_private.registration_management_scopes enable row level security;
revoke all on app_private.registration_management_scopes from public,anon,authenticated;
create table app_private.registration_composition_mail_compatibility (
 group_id uuid not null references app_private.walking_groups(id),mail_hash text not null,mail_revision integer not null,
 current_hash text not null,current_revision integer not null,command_id uuid not null,
 primary key(group_id,mail_hash,mail_revision)
);
alter table app_private.registration_composition_mail_compatibility enable row level security;
revoke all on app_private.registration_composition_mail_compatibility from public,anon,authenticated;

create table app_private.registration_management_schedule_preferences (
 schedule_id uuid primary key references app_private.group_schedule_revisions(id),group_id uuid not null references app_private.walking_groups(id),
 dominant_end_at timestamptz,composition_hash text not null,command_id uuid not null
);
alter table app_private.registration_management_schedule_preferences enable row level security;
revoke all on app_private.registration_management_schedule_preferences from public,anon,authenticated;

create or replace function app_private.schedule_latest_finale_arrival(_schedule uuid)
returns timestamptz language sql stable security definer set search_path='' as $$
 select least(settings.finale_last_arrival_at,settings.finale_closes_at-make_interval(secs=>settings.finale_show_seconds+settings.finale_turnover_seconds),
  (case when approved.schedule_id is not null then approved.dominant_end_at
   when s.input_snapshot ? 'dominantEndAt' then (s.input_snapshot->>'dominantEndAt')::timestamptz
   else app_private.dominant_end_preference(array(select distinct a.registration_id from app_private.group_registrations a where a.group_id=s.group_id and a.superseded_at is null)) end)
   +make_interval(secs=>app_private.group_end_overrun_seconds()-settings.finale_show_seconds))
 from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id
 join app_private.event_route_settings settings on settings.event_id=g.event_id
 left join app_private.registration_management_schedule_preferences approved on approved.schedule_id=s.id and approved.group_id=g.id
  and approved.composition_hash=app_private.start_group_composition_hash(g.id) where s.id=_schedule
$$;
revoke all on function app_private.schedule_latest_finale_arrival(uuid) from public,anon,authenticated;

create function app_private.admin_registration_group_started(_group uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.walking_groups g where g.id=_group and
  (g.status in ('live','completed','stopped') or exists(select 1 from app_private.group_runs r where r.group_id=g.id
   and (r.started_at is not null or r.status in ('live','paused','completed','stopped')
    or exists(select 1 from app_private.run_stops stop where stop.run_id=r.id and (stop.opened_at is not null or stop.completed_at is not null
     or exists(select 1 from app_private.run_stop_arrivals arrival where arrival.run_stop_id=stop.id and arrival.arrived)
     or exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=stop.id)))))))
$$;
create function app_private.admin_registration_scope_begin(_event uuid,_registration uuid,_groups uuid[],_command uuid)
returns void language plpgsql security definer set search_path='' as $$
declare before_data jsonb;
begin
 if auth.uid() is null or not(app_private.has_capability(_event,'event_admin',auth.uid()) or app_private.has_capability(_event,'registration_manage',auth.uid()))
  or not exists(select 1 from app_private.registrations where id=_registration and event_id=_event) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from app_private.events where id=_event for update;
 perform 1 from app_private.walking_groups where id=any(_groups) order by id for update;
 if exists(select 1 from unnest(_groups) supplied(id) where not exists(select 1 from app_private.walking_groups g where g.id=supplied.id and g.event_id=_event and g.retired_at is null)) then
  raise exception 'GROUP_NOT_FOUND' using errcode='P0002'; end if;
 if exists(select 1 from unnest(_groups) supplied(id) where app_private.admin_registration_group_started(supplied.id)) then
  raise exception 'REGISTRATION_GROUP_ALREADY_STARTED' using errcode='23514',hint='Een begonnen groep vereist de bestaande veilige overdrachtsprocedure; de bezoekhistorie blijft behouden.'; end if;
 select coalesce(jsonb_object_agg(g.id::text,jsonb_build_object(
  'children',(select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null),
  'hash',app_private.start_group_composition_hash(g.id),'confirmedHash',g.composition_confirmed_hash,'revision',g.composition_revision,
  'confirmedSchedules',coalesce((select jsonb_object_agg(s.id::text,app_private.start_composition_hash_current(s.id,g.id,s.confirmed_composition_hash)) from app_private.group_schedule_revisions s where s.group_id=g.id and s.confirmed_at is not null),'{}'))),'{}')
 into before_data from app_private.walking_groups g where g.id=any(_groups);
 if exists(select 1 from jsonb_each(before_data) item where item.value->>'confirmedHash' is not null and item.value->>'confirmedHash' is distinct from item.value->>'hash') then
  raise exception 'GROUP_COMPOSITION_ALREADY_STALE' using errcode='40001'; end if;
 insert into app_private.registration_management_scopes(transaction_id,backend_pid,command_id,event_id,registration_id,actor_id,group_ids,before_groups)
 values(txid_current(),pg_backend_pid(),_command,_event,_registration,auth.uid(),coalesce(_groups,'{}'),before_data);
end $$;
create function app_private.admin_registration_scope_end(_command uuid) returns void
language sql security definer set search_path='' as $$
 delete from app_private.registration_management_scopes where transaction_id=txid_current() and backend_pid=pg_backend_pid() and actor_id=auth.uid() and command_id=_command
$$;

create or replace function app_private.protect_confirmed_composition()
returns trigger language plpgsql security definer set search_path='' as $$
declare gids uuid[]; rid uuid;
begin
 if tg_op='UPDATE' and new.group_id=old.group_id and new.registration_id=old.registration_id and new.superseded_at is not distinct from old.superseded_at then return new; end if;
 gids:=case when tg_op='DELETE' then array[old.group_id] when tg_op='INSERT' then array[new.group_id] else array[old.group_id,new.group_id] end;
 rid:=case when tg_op='DELETE' then old.registration_id else new.registration_id end;
 if exists(select 1 from app_private.walking_groups where id=any(gids) and composition_confirmed_hash is not null)
 and not exists(select 1 from app_private.registration_management_scopes scope where scope.transaction_id=txid_current() and scope.backend_pid=pg_backend_pid()
  and scope.actor_id=auth.uid() and scope.registration_id=rid and gids<@scope.group_ids
  and (tg_op<>'UPDATE' or old.registration_id=new.registration_id)) then
  raise exception 'COMPOSITION_REOPEN_REQUIRED' using errcode='23514'; end if;
 if tg_op='DELETE' then return old; else return new; end if;
end $$;

create function app_private.registration_management_composition_mail_current(_group uuid,_hash text,_revision integer)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.walking_groups g where g.id=_group and g.retired_at is null
  and g.composition_confirmed_hash=app_private.start_group_composition_hash(g.id)
  and ((g.composition_confirmed_hash=_hash and g.composition_revision=_revision)
   or exists(select 1 from app_private.registration_composition_mail_compatibility c where c.group_id=g.id and c.mail_hash=_hash and c.mail_revision=_revision
    and c.current_hash=g.composition_confirmed_hash and c.current_revision=g.composition_revision)))
$$;
create function app_private.admin_registration_sync_prepared_roster(_group uuid) returns void
language plpgsql security definer set search_path='' as $$
declare prepared app_private.group_runs;
begin
 if not exists(select 1 from app_private.registration_management_scopes scope where scope.transaction_id=txid_current() and scope.backend_pid=pg_backend_pid() and scope.actor_id=auth.uid() and _group=any(scope.group_ids)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if app_private.admin_registration_group_started(_group) then raise exception 'REGISTRATION_GROUP_ALREADY_STARTED' using errcode='23514'; end if;
 for prepared in select * from app_private.group_runs r where r.group_id=_group and r.status='ready' and r.started_at is null order by id for update loop
  update app_private.run_participants participant set attendance='absent',roster_version=roster_version+1
   where participant.run_id=prepared.id and participant.attendance<>'absent' and not exists(
    select 1 from app_private.group_registrations assignment join app_private.registration_children child on child.registration_id=assignment.registration_id and child.participation_status='active'
    where assignment.group_id=_group and assignment.superseded_at is null and child.id=participant.registration_child_id);
  update app_private.stop_participant_statuses status set required_for_completion=false,exclusion_reason='Deelname vóór vertrek gewijzigd',changed_by=auth.uid(),reason='Gerichte beheerwijziging vóór daadwerkelijk vertrek',version=status.version+1
   from app_private.run_participants participant where participant.id=status.run_participant_id and participant.run_id=prepared.id and participant.attendance='absent' and status.required_for_completion;
  insert into app_private.run_participants(run_id,registration_child_id,attendance)
   select prepared.id,child.id,'absent' from app_private.group_registrations assignment join app_private.registration_children child on child.registration_id=assignment.registration_id and child.participation_status='active'
   where assignment.group_id=_group and assignment.superseded_at is null on conflict(run_id,registration_child_id) do nothing;
  update app_private.group_runs set version=version+1,updated_at=clock_timestamp() where id=prepared.id;
 end loop;
end $$;

create function app_private.admin_registration_refresh_group(_group uuid,_actor uuid)
returns void language plpgsql security definer set search_path='' as $$
<<registration_refresh>>
declare g app_private.walking_groups; scope app_private.registration_management_scopes; previous jsonb; current_hash text; next_revision integer; schedule app_private.group_schedule_revisions;
begin
 select * into scope from app_private.registration_management_scopes where transaction_id=txid_current() and backend_pid=pg_backend_pid() and actor_id=auth.uid() and _group=any(group_ids);
 if scope.command_id is null or _actor is distinct from auth.uid() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into g from app_private.walking_groups where id=_group for update;
 previous:=scope.before_groups->_group::text; current_hash:=app_private.start_group_composition_hash(_group);
 next_revision:=g.composition_revision+1;
 if previous->>'confirmedHash' is not null then
  update app_private.registration_composition_mail_compatibility set current_hash=registration_refresh.current_hash,current_revision=next_revision,command_id=scope.command_id
   where registration_composition_mail_compatibility.group_id=_group and registration_composition_mail_compatibility.current_hash=previous->>'hash' and registration_composition_mail_compatibility.current_revision=(previous->>'revision')::integer;
  insert into app_private.registration_composition_mail_compatibility(group_id,mail_hash,mail_revision,current_hash,current_revision,command_id)
   values(_group,previous->>'hash',(previous->>'revision')::integer,current_hash,next_revision,scope.command_id)
   on conflict(group_id,mail_hash,mail_revision) do update set current_hash=excluded.current_hash,current_revision=excluded.current_revision,command_id=excluded.command_id;
 end if;
 update app_private.walking_groups set composition_confirmed_hash=case when previous->>'confirmedHash' is not null then current_hash else composition_confirmed_hash end,
  composition_revision=next_revision,version=version+1,updated_at=clock_timestamp() where id=_group;
 -- Keep every immutable start publication and its original confirmation fields.
 -- Only the structural-compatibility anchor advances for supported commands.
 for schedule in select s.* from app_private.group_schedule_revisions s where s.group_id=_group and s.confirmed_at is not null
  and (s.id=g.current_schedule_revision_id or exists(select 1 from app_private.current_start_publication(_group) p where p.schedule_id=s.id))
  and coalesce((previous#>>array['confirmedSchedules',s.id::text])::boolean,false) loop
  insert into app_private.start_composition_hash_compatibility(schedule_id,group_id,legacy_hash,structural_hash)
  values(schedule.id,_group,schedule.confirmed_composition_hash,current_hash)
  on conflict(schedule_id) do update set legacy_hash=excluded.legacy_hash,structural_hash=excluded.structural_hash;
 end loop;
 insert into app_private.registration_management_schedule_preferences(schedule_id,group_id,dominant_end_at,composition_hash,command_id)
 select s.id,_group,app_private.dominant_end_preference(array(select a.registration_id from app_private.group_registrations a where a.group_id=_group and a.superseded_at is null)),current_hash,scope.command_id
 from app_private.group_schedule_revisions s where s.group_id=_group and (s.id=g.current_schedule_revision_id or exists(select 1 from app_private.current_start_publication(_group) p where p.schedule_id=s.id))
 on conflict(schedule_id) do update set dominant_end_at=excluded.dominant_end_at,composition_hash=excluded.composition_hash,command_id=excluded.command_id;
 perform app_private.admin_registration_sync_prepared_roster(_group);

end $$;

create function app_private.admin_registration_assert_group_capacity(_group uuid)
returns void language plpgsql security definer set search_path='' as $$
declare g app_private.walking_groups; children integer; maximum integer; baseline integer; schedule_ids uuid[]; visit record;
 settings app_private.event_route_settings; published app_private.group_start_publications; slot app_private.start_slots; point app_private.start_points; load_children integer; load_groups integer; desired_end timestamptz; hard_stop timestamptz; portal app_private.portals; until_at timestamptz; notices jsonb; notice jsonb; scope app_private.registration_management_scopes;
begin
 select * into g from app_private.walking_groups where id=_group for update;
 if g.id is null then raise exception 'GROUP_NOT_FOUND' using errcode='P0002'; end if;
 if app_private.admin_registration_group_started(_group) then raise exception 'REGISTRATION_GROUP_ALREADY_STARTED' using errcode='23514'; end if;
 select count(*)::integer into children from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=_group and a.superseded_at is null;
 select * into scope from app_private.registration_management_scopes where transaction_id=txid_current() and backend_pid=pg_backend_pid() and _group=any(group_ids) and actor_id=auth.uid();
 baseline:=coalesce((scope.before_groups#>>array[_group::text,'children'])::integer,children); maximum:=app_private.event_group_size_limit(g.event_id);
 if children>greatest(maximum,baseline) then raise exception 'REGISTRATION_GROUP_CAPACITY_EXCEEDED' using errcode='23514',detail=jsonb_build_object('requiredChildren',children,'availableChildren',greatest(maximum,baseline),'needed',children,'available',greatest(maximum,baseline),'groupCode',g.system_code)::text; end if;
 if children=0 then return; end if;
 select * into settings from app_private.event_route_settings where event_id=g.event_id;
 select app_private.dominant_end_preference(array_agg(r.id)),min(r.requested_ordinary_stop_at) filter(where r.requested_ordinary_stop_at is distinct from r.desired_end_at) into desired_end,hard_stop
 from app_private.group_registrations a join app_private.registrations r on r.id=a.registration_id where a.group_id=_group and a.superseded_at is null;
 select array_agg(distinct id) into schedule_ids from app_private.group_schedule_revisions s where s.group_id=_group
  and (s.id=g.current_schedule_revision_id or exists(select 1 from app_private.current_start_publication(_group) p where p.schedule_id=s.id));
 if cardinality(schedule_ids)>0 then
  begin perform app_private.assert_start_schedule_capacity_readonly(g.event_id,schedule_ids);
  exception when check_violation then raise exception 'REGISTRATION_PHYSICAL_CAPACITY_OR_TIME_CONFLICT' using errcode='23514',detail=jsonb_build_object('requiredChildren',children,'needed',children,'groupCode',g.system_code,'constraint',sqlerrm)::text; end;
 else
  -- Legacy published appointments have no dynamic schedule row. Their frozen
  -- start still reserves departure, gathering and linked-house capacity.
  select * into published from app_private.current_start_publication(_group);
  select * into slot from app_private.start_slots where id=coalesce((published.slot_snapshot->>'id')::uuid,g.start_slot_id);
  select * into point from app_private.start_points where id=slot.start_point_id;
  if published.id is not null then
   slot:=jsonb_populate_record(null::app_private.start_slots,published.slot_snapshot);
   point:=jsonb_populate_record(null::app_private.start_points,published.point_snapshot);
   slot.starts_at:=published.starts_at;
  end if;
  if slot.id is not null and point.id is not null then
   select count(*),coalesce(sum(n),0)::integer into load_groups,load_children from (
    select r.group_id,max(r.child_count) n from app_private.start_schedule_reservations(g.event_id) r
    where r.group_id<>_group and r.start_point_id=point.id and floor(extract(epoch from r.starts_at)/600)=floor(extract(epoch from slot.starts_at)/600) group by r.group_id) occupied;
   if load_groups+1>least(slot.max_groups,point.max_gathering_groups) or load_children+children>least(slot.max_children,point.max_gathering_children) then
    raise exception 'REGISTRATION_START_CAPACITY_EXCEEDED' using errcode='23514',detail=jsonb_build_object('requiredChildren',children,'needed',children,'availableChildren',greatest(0,least(slot.max_children,point.max_gathering_children)-load_children),'available',greatest(0,least(slot.max_children,point.max_gathering_children)-load_children),'groupCode',g.system_code)::text;
   end if;
   if exists(select 1 from app_private.start_schedule_reservations(g.event_id) r where r.group_id<>_group
    and floor(extract(epoch from r.starts_at)/600)=floor(extract(epoch from slot.starts_at)/600)
    and app_private.reserved_departure_key(r.group_id,r.schedule_id,r.start_point_id)=app_private.reserved_departure_key(_group,published.schedule_id,point.id)) then
    raise exception 'START_DEPARTURE_OCCUPIED' using errcode='23514'; end if;
   if not app_private.start_point_ready_at(point.id,slot.starts_at) or(point.linked_portal_id is not null and not app_private.portal_interval_available(point.linked_portal_id,_group,slot.starts_at,slot.starts_at+make_interval(secs=>app_private.portal_service_seconds(point.linked_portal_id,slot.starts_at)),children,statement_timestamp())) then
    raise exception 'REGISTRATION_START_CAPACITY_EXCEEDED' using errcode='23514',detail=jsonb_build_object('requiredChildren',children,'needed',children,'groupCode',g.system_code,'constraint','LINKED_START_PORTAL')::text;
   end if;
  end if;
 end if;
 -- Even legacy/nonstandard reservations cannot create a second physical
 -- departure inside the same ten-minute bucket.
 if exists(select 1 from app_private.start_schedule_reservations(g.event_id) own join app_private.start_schedule_reservations(g.event_id) other
  on own.group_id=_group and other.group_id<>_group
  and floor(extract(epoch from own.starts_at)/600)=floor(extract(epoch from other.starts_at)/600)
  and app_private.reserved_departure_key(own.group_id,own.schedule_id,own.start_point_id)=app_private.reserved_departure_key(other.group_id,other.schedule_id,other.start_point_id)) then
  raise exception 'START_DEPARTURE_OCCUPIED' using errcode='23514'; end if;
 -- Accepted board/legacy visits remain fixed. Validate their complete physical
 -- intervals with the changed roster; never silently regenerate an accepted route.
 for visit in
  select v.portal_id,v.starts_at,v.duration_seconds+v.buffer_seconds service,v.duration_seconds visit_seconds,v.kind from app_private.live_route_visits v where v.group_id=_group and v.retired_at is null and v.kind<>'start'
  union all select p.portal_id,p.planned_arrival_at,extract(epoch from p.planned_departure_at-p.planned_arrival_at)::integer,extract(epoch from p.planned_departure_at-p.planned_arrival_at)::integer,
   case when p.position=(select max(last.position) from app_private.route_plan_stops last where last.plan_version_id=g.current_plan_version_id) then 'finale' else 'ordinary' end
  from app_private.route_plan_stops p where g.route_mode='legacy' and p.plan_version_id=g.current_plan_version_id and not exists(select 1 from app_private.live_route_visits v where v.group_id=_group and v.retired_at is null)
 loop
  until_at:=visit.starts_at+make_interval(secs=>visit.service);
  select * into portal from app_private.portals where id=visit.portal_id;
  if portal.lifecycle_status<>'active' or portal.approval_status<>'approved' or portal.operation_status in ('closed','paused')
   or not app_private.portal_interval_available(visit.portal_id,_group,visit.starts_at,until_at,children,statement_timestamp())
   or (visit.kind<>'finale' and visit.starts_at+make_interval(secs=>visit.visit_seconds)>least(settings.global_ordinary_stop_at,hard_stop))
   or (visit.kind='finale' and (visit.starts_at+make_interval(secs=>settings.finale_show_seconds)>desired_end+make_interval(secs=>app_private.group_end_overrun_seconds()) or visit.starts_at>settings.finale_last_arrival_at or until_at>settings.finale_closes_at)) then
   raise exception 'REGISTRATION_ROUTE_CAPACITY_EXCEEDED' using errcode='23514',detail=jsonb_build_object('requiredChildren',children,'portalCode',portal.system_code,'groupCode',g.system_code,
    'availableChildren',(select max(w.max_children_per_visit) from app_private.portal_windows w where w.portal_id=visit.portal_id and visit.starts_at>=w.opens_at and until_at<=w.closes_at))::text;
  end if;
 end loop;
 if exists(select 1 from app_private.live_route_visits where group_id=_group and retired_at is null) then
  notices:=app_private.live_planboard_warnings(g.event_id,'[]'::jsonb);
  select value into notice from jsonb_array_elements(notices) where value->>'severity'='block' and value->>'code' not in('ACCESSIBILITY_UNSUITABLE','ACCESSIBILITY_REQUIREMENT','ACCESSIBILITY_REVIEW_REQUIRED','ACCEPTED_ROUTE_STALE','JOINT_ROUTE_REVIEW_REQUIRED') and value->'groupIds' @> jsonb_build_array(_group) limit 1;
  if notice is not null then raise exception 'REGISTRATION_ROUTE_CAPACITY_EXCEEDED' using errcode='23514',detail=jsonb_build_object('requiredChildren',children,'groupCode',g.system_code,'constraint',notice->>'code')::text; end if;
 end if;
end $$;

create function app_private.admin_registration_group_choice(_group uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',g.id,'version',g.version,'code',g.system_code,'name',coalesce(g.display_name,g.system_code),
  'children',(select count(*) from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null),
  'maxChildren',app_private.event_group_size_limit(g.event_id),'status',g.status,
  'confirmed',g.composition_confirmed_hash is not null or p.id is not null or s.confirmed_at is not null,
  'compositionConfirmed',coalesce(g.composition_confirmed_hash=app_private.start_group_composition_hash(g.id),false),
  'startConfirmed',p.id is not null,'startChecked',app_private.is_start_confirmation_current(s.id),
  'startPointCode',coalesce(p.point_snapshot->>'public_label',p.point_snapshot->>'name',point.public_label,point.name),'startsAt',coalesce(p.starts_at,slot.starts_at),
  'desiredEndAt',app_private.dominant_end_preference(array(select a.registration_id from app_private.group_registrations a where a.group_id=g.id and a.superseded_at is null)),
  'expectedCompletionAt',s.expected_finale_arrival_at+make_interval(secs=>settings.finale_show_seconds),'started',app_private.admin_registration_group_started(g.id))
 from app_private.walking_groups g left join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
 left join app_private.start_slots slot on slot.id=coalesce(s.start_slot_id,g.start_slot_id)
 left join app_private.start_points point on point.id=slot.start_point_id
 left join lateral app_private.current_start_publication(g.id) p on true
 left join app_private.event_route_settings settings on settings.event_id=g.event_id where g.id=_group
$$;
create function api.admin_registration_management_preview(_event_slug text,_registration_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
<<manage_preview>>
declare e app_private.events; r app_private.registrations; result jsonb; group_id uuid; party_id uuid; others integer;
begin
 select * into e from app_private.events where slug=_event_slug;
 if auth.uid() is null or e.id is null or not(app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'registration_manage',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into r from app_private.registrations where id=_registration_id and event_id=e.id;
 if r.id is null then raise exception 'REGISTRATION_NOT_FOUND' using errcode='P0002'; end if;
 select a.group_id into group_id from app_private.group_registrations a where a.registration_id=r.id and a.superseded_at is null;
 select m.party_id into party_id from app_private.together_memberships m where m.registration_id=r.id and m.left_at is null;
 select count(*)::integer into others from app_private.together_memberships m join app_private.registrations member on member.id=m.registration_id and member.status='submitted' where m.party_id=manage_preview.party_id and m.left_at is null and m.registration_id<>r.id;
 result:=jsonb_build_object('registrationId',r.id,'version',r.version,'sourceGroup',app_private.admin_registration_group_choice(group_id),
  'children',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'childId',c.child_id,'firstName',profile.first_name,'ageAtEvent',profile.age_at_event,'accessibilityNote',profile.accessibility_note,'stepFreeRequired',profile.step_free_required,'stepFreeNeedsReview',app_private.child_step_free_requirement(profile.id) is null,'participationStatus',c.participation_status,'unitPriceCents',c.unit_price_cents) order by c.created_at,c.id)
   from app_private.registration_children c join app_private.children profile on profile.id=c.child_id where c.registration_id=r.id),'[]'),
  'groups',coalesce((select jsonb_agg(app_private.admin_registration_group_choice(g.id) order by g.system_number,g.id) from app_private.walking_groups g where g.event_id=e.id and g.retired_at is null),'[]'),
  'together',jsonb_build_object('partyId',party_id,'otherHouseholds',others,'splitOnMove',others>0),
  'canEdit',r.status='submitted' and not app_private.admin_registration_group_started(group_id),
  'canMove',r.status='submitted' and not app_private.admin_registration_group_started(group_id) and(app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'groups_manage',auth.uid())));
 return result||jsonb_build_object('inputHash',encode(extensions.digest(convert_to(jsonb_build_array(result,app_private.start_planning_input_hash(e.id))::text,'UTF8'),'sha256'),'hex'));
end $$;

create function api.admin_registration_manage_apply(_event_slug text,_registration_id uuid,_action text,_payload jsonb,_input_hash text,_reason text,_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
<<manage_apply>>
declare e app_private.events; r app_private.registrations; previous app_private.command_receipts; command_id uuid:=gen_random_uuid(); hashed text; preview jsonb; result jsonb;
 assignment app_private.group_registrations; new_assignment app_private.group_registrations; source_group uuid; target_group uuid; affected uuid[]; group_id uuid;
 item jsonb; child app_private.registration_children; profile app_private.children; kept uuid[]:='{}'; old_children integer; new_children integer; old_amount integer; new_amount integer;
 changed boolean:=false; party_id uuid; other_members integer; new_party uuid; parent_id uuid; recipient_email text; batch record; payment app_private.payment_requests; pub app_private.group_start_publications;
 target_schedule uuid; before_totals jsonb; revision integer;
begin
 select * into e from app_private.events where slug=_event_slug for update;
 if auth.uid() is null or e.id is null or not(app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'registration_manage',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _action is null or _action not in ('edit_children','move') or jsonb_typeof(_payload) is distinct from 'object' or char_length(trim(coalesce(_reason,''))) not between 10 and 500 or coalesce(_idempotency_key,'')!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 if _action='move' and not(app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'groups_manage',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 hashed:=encode(extensions.digest(convert_to(jsonb_build_array(e.id,_registration_id,_action,_payload,_input_hash,trim(_reason))::text,'UTF8'),'sha256'),'hex');
 select * into previous from app_private.command_receipts where actor_id=auth.uid() and command_type='registration.manage' and idempotency_key=_idempotency_key;
 if previous.id is not null then if previous.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505'; end if; return previous.safe_result; end if;
 select * into r from app_private.registrations where id=_registration_id and event_id=e.id and status='submitted' for update;
 if r.id is null then raise exception 'REGISTRATION_NOT_FOUND' using errcode='P0002'; end if;
 select * into assignment from app_private.group_registrations a where a.registration_id=r.id and a.superseded_at is null for update;
 source_group:=assignment.group_id; target_group:=case when _action='move' then nullif(_payload->>'targetGroupId','')::uuid else source_group end;
 if _action='move' and target_group is null then raise exception 'TARGET_GROUP_REQUIRED' using errcode='22023'; end if;
 -- A same-group selection is an unconditional identity-preserving no-op. It
 -- cannot supersede a real pending move notification, even with an older preview.
 if _action='move' and target_group is not distinct from source_group then
  result:=jsonb_build_object('registrationId',r.id,'version',r.version,'groupId',source_group,'changed',false,'mailQueued',false);
 else
  preview:=api.admin_registration_management_preview(_event_slug,r.id);
  if _input_hash is distinct from preview->>'inputHash' then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  select array_agg(distinct id order by id) into affected from unnest(array[source_group,target_group]) q(id) where id is not null;
  perform app_private.admin_registration_scope_begin(e.id,r.id,coalesce(affected,'{}'),command_id);
  select count(*)::integer,coalesce(sum(unit_price_cents),0)::integer into old_children,old_amount from app_private.registration_children where registration_id=r.id and participation_status='active';
  before_totals:=jsonb_build_object('childCount',old_children,'amountCents',old_amount,'groupId',source_group);
  if _action='edit_children' then
   if jsonb_typeof(_payload->'children') is distinct from 'array' then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
   if jsonb_array_length(_payload->'children')=0 then raise exception 'LAST_CHILD_REQUIRES_CANCELLATION' using errcode='23514'; end if;
   if jsonb_array_length(_payload->'children')>app_private.event_group_size_limit(e.id) and jsonb_array_length(_payload->'children')>old_children then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514'; end if;
   for item in select value from jsonb_array_elements(_payload->'children') loop
    if jsonb_typeof(item)<>'object' or char_length(trim(coalesce(item->>'firstName',''))) not between 1 and 80 or coalesce(item->>'ageAtEvent','')!~'^[0-9]{1,2}$' or (item->>'ageAtEvent')::integer not between 0 and 20 or char_length(coalesce(item->>'accessibilityNote',''))>500 or (item?'stepFreeRequired' and jsonb_typeof(item->'stepFreeRequired') not in ('boolean','null')) then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
    if nullif(item->>'id','') is not null then
     select * into child from app_private.registration_children where id=(item->>'id')::uuid and registration_id=r.id and participation_status='active' for update;
     if child.id is null or child.id=any(kept) then raise exception 'INVALID_REGISTRATION_CHILD' using errcode='23514'; end if;
     kept:=array_append(kept,child.id);
    end if;
   end loop;
   -- Release participation first so replacing a child at a full limit has no
   -- transient double count. Stable child, passport and payment rows survive.
   changed:=exists(select 1 from app_private.registration_children where registration_id=r.id and participation_status='active' and not(id=any(kept)));
   update app_private.registration_children set participation_status='cancelled' where registration_id=r.id and participation_status='active' and not(id=any(kept));
   for item in select value from jsonb_array_elements(_payload->'children') loop
    if nullif(item->>'id','') is not null then
     select * into child from app_private.registration_children where id=(item->>'id')::uuid;
     select * into profile from app_private.children where id=child.child_id for update;
     if profile.first_name is distinct from trim(item->>'firstName') or profile.age_at_event is distinct from (item->>'ageAtEvent')::smallint or profile.accessibility_note is distinct from nullif(trim(coalesce(item->>'accessibilityNote','')),'') or (item?'stepFreeRequired' and profile.step_free_required is distinct from (item->>'stepFreeRequired')::boolean) then
      update app_private.children set first_name=trim(item->>'firstName'),age_at_event=(item->>'ageAtEvent')::smallint,accessibility_note=nullif(trim(coalesce(item->>'accessibilityNote','')),''),step_free_required=case when item?'stepFreeRequired' then (item->>'stepFreeRequired')::boolean else step_free_required end,version=version+1,updated_at=clock_timestamp() where id=child.child_id;
      changed:=true;
     end if;
    else
     insert into app_private.children(household_id,first_name,age_at_event,accessibility_note,step_free_required) values(r.household_id,trim(item->>'firstName'),(item->>'ageAtEvent')::smallint,nullif(trim(coalesce(item->>'accessibilityNote','')),''),(item->>'stepFreeRequired')::boolean) returning * into profile;
     insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents) values(e.id,r.id,profile.id,e.price_cents);
     changed:=true;
    end if;
   end loop;
   select count(*)::integer,coalesce(sum(unit_price_cents),0)::integer into new_children,new_amount from app_private.registration_children where registration_id=r.id and participation_status='active';
   if (select count(*) from app_private.registration_children where event_id=e.id and participation_status='active')>coalesce((e.settings->>'maxChildren')::integer,300) and new_children>old_children then raise exception 'EVENT_CAPACITY_REACHED' using errcode='23514'; end if;
   if changed then
    -- Paid ledgers and confirmed batches are historical facts. Only open links
    -- whose roster/amount changed are retired; no refund/collection is executed.
    if old_amount<>new_amount then
     for batch in select distinct b.id from app_private.child_payment_batches b join app_private.registration_children c on c.child_payment_batch_id=b.id where c.registration_id=r.id and c.participation_status='cancelled' and b.status in ('awaiting_payment','reported') order by b.id loop
      update app_private.child_payment_batches set status='cancelled',version=version+1 where id=batch.id;
      update app_private.registration_children set child_payment_batch_id=null where child_payment_batch_id=batch.id;
     end loop;
     select * into payment from app_private.payment_requests where registration_id=r.id order by created_at desc limit 1 for update;
     if payment.payment_batch_id is not null and exists(select 1 from app_private.payment_link_batches b where b.id=payment.payment_batch_id and b.status='awaiting_payment') then
      update app_private.payment_link_batches set status='cancelled',version=version+1,updated_at=clock_timestamp() where id=payment.payment_batch_id;
      update app_private.payment_requests set external_url=null,payment_batch_id=null,version=version+1 where payment_batch_id=payment.payment_batch_id;
     else update app_private.payment_requests set external_url=null where id=payment.id and status in ('awaiting_link','awaiting_payment','reported') and not exists(select 1 from app_private.payment_entries entry where entry.request_id=payment.id and entry.entry_type<>'reported' and entry.amount_cents<>0); end if;
     perform app_private.reconcile_registration_payment(r.id);
    end if;
    update app_private.registrations set price_snapshot_cents=new_amount,version=version+1,updated_at=clock_timestamp() where id=r.id returning * into r;
   end if;
  else
   if not exists(select 1 from app_private.walking_groups where id=target_group and event_id=e.id and retired_at is null) then raise exception 'GROUP_NOT_FOUND' using errcode='P0002'; end if;
   select h.primary_contact_user_id into parent_id from app_private.households h where h.id=r.household_id;
   if source_group is not null and app_private.is_current_leader(source_group,parent_id)
    and (select count(*) from app_private.group_leaders l where l.group_id=source_group and l.active_from<=now() and(l.active_until is null or l.active_until>now()))=1 then
    raise exception 'GROUP_LEADER_REPLACEMENT_REQUIRED' using errcode='23514',hint='Wijs eerst via het bestaande groepsleiderbeheer een bevoegde vervanger voor de brongroep aan.'; end if;
   select m.party_id into party_id from app_private.together_memberships m where m.registration_id=r.id and m.left_at is null for update;
   select count(*)::integer into other_members from app_private.together_memberships m where m.party_id=manage_apply.party_id and m.left_at is null and m.registration_id<>r.id;
   if other_members>0 then
    update app_private.together_memberships set left_at=clock_timestamp() where registration_id=r.id and left_at is null;
    insert into app_private.together_parties(event_id,public_label,creator_household_id,invite_token_hash,expires_at)
     values(e.id,'Samenloopcode '||r.together_code,r.household_id,extensions.digest(convert_to('admin-move:'||command_id,'UTF8'),'sha256'),now()+interval '10 years') returning id into new_party;
    insert into app_private.together_memberships(party_id,registration_id) values(new_party,r.id);
    -- Withdraw only this household's still-pending join request; otherwise a
    -- later acceptance could undo this explicit administrator choice.
    update app_private.together_join_requests set status='withdrawn',decided_at=clock_timestamp(),decided_by=auth.uid(),decision_reason=left(trim(_reason),500),version=version+1 where requested_by_registration_id=r.id and status='pending';
   end if;
   if assignment.id is not null then update app_private.group_registrations set superseded_at=clock_timestamp() where id=assignment.id; end if;
   select coalesce(max(assignment_revision),0)+1 into revision from app_private.group_registrations where registration_id=r.id;
   select * into pub from app_private.current_start_publication(target_group);
   insert into app_private.group_registrations(group_id,registration_id,assignment_revision,published_at) values(target_group,r.id,revision,pub.published_at) returning * into new_assignment;
   update app_private.registrations set version=version+1,updated_at=clock_timestamp() where id=r.id returning * into r;
   changed:=true;
  end if;
  if changed then
   foreach group_id in array coalesce(affected,'{}') loop
    perform app_private.admin_registration_assert_group_capacity(group_id);
    perform app_private.admin_registration_refresh_group(group_id,auth.uid());
   end loop;
   select current_schedule_revision_id into target_schedule from app_private.walking_groups where id=target_group;
   insert into app_private.registration_management_changes(id,event_id,registration_id,action,actor_id,source_group_id,target_group_id,group_registration_id,target_schedule_id,registration_version)
    values(command_id,e.id,r.id,_action,auth.uid(),source_group,target_group,coalesce(new_assignment.id,assignment.id),target_schedule,r.version);
   insert into app_private.registration_revisions(registration_id,version,changed_by,change_type,totals_before,totals_after)
    values(r.id,r.version,auth.uid(),'admin_'||_action,before_totals,jsonb_build_object('childCount',coalesce(new_children,old_children),'amountCents',coalesce(new_amount,old_amount),'groupId',target_group));
   insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,correlation_id,minimal_change)
    values(e.id,auth.uid(),'registration.admin_'||_action,'registration',r.id,command_id::text,jsonb_build_object('sourceGroupId',source_group,'targetGroupId',target_group,'version',r.version,'reason',trim(_reason),'childCount',coalesce(new_children,old_children)));
   if _action='move' then
    select lower(u.email) into recipient_email from app_private.households h join auth.users u on u.id=h.primary_contact_user_id and u.email_confirmed_at is not null and u.deleted_at is null where h.id=r.household_id;
    if recipient_email is null then
     execute 'select normalized_email from app_private.registration_activations where registration_id=$1 and activated_at is null' into recipient_email using r.id;
    end if;
    if recipient_email is null then raise exception 'REGISTRATION_PARENT_RECIPIENT_MISSING' using errcode='23514'; end if;
    update app_private.email_outbox set status='suppressed',last_error_code='REGISTRATION_MOVE_SUPERSEDED',lease_until=null where message_type='registration_group_changed' and payload->>'registrationId'=r.id::text and status in ('pending','deferred','processing');
    -- Existing other-family messages are byte-for-byte preserved. A retained
    -- independent leader role still receives its own valid source-group mail.
    if parent_id is not null and not exists(select 1 from app_private.group_adult_recipients(source_group) rec where rec.user_id=parent_id) then
     update app_private.email_outbox set status='suppressed',last_error_code='REGISTRATION_MOVED',lease_until=null where recipient_ref=parent_id::text and payload->>'groupId'=source_group::text and message_type in ('group_schedule_published','group_schedule_corrected','group_composition_confirmed','group_assignment_withdrawn') and status in ('pending','deferred','processing');
    end if;
    insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
     values('registration-group-change:'||command_id,'registration_group_changed','registration:'||r.id,recipient_email,jsonb_build_object('registrationId',r.id,'commandId',command_id,'sourceGroupId',source_group,'targetGroupId',target_group,'groupRegistrationId',new_assignment.id,'targetScheduleId',target_schedule,'actionPath','/omgeving/meeloper/groep'));
   end if;
   perform realtime.send(jsonb_build_object('resource','registration','registrationId',r.id),'snapshot_changed','admin-event:'||e.id,true);
   foreach group_id in array coalesce(affected,'{}') loop perform realtime.send(jsonb_build_object('resource','composition'),'snapshot_changed','group:'||group_id,true); end loop;
  end if;
  perform app_private.admin_registration_scope_end(command_id);
  result:=jsonb_build_object('registrationId',r.id,'version',r.version,'groupId',target_group,'changed',changed,'mailQueued',changed and _action='move','commandId',case when changed then command_id else null end);
 end if;
 insert into app_private.command_receipts(id,actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(command_id,auth.uid(),'registration.manage',_idempotency_key,hashed,result,now()+interval '30 days');
 return result;
end $$;

revoke all on function app_private.admin_registration_group_started(uuid),app_private.admin_registration_scope_begin(uuid,uuid,uuid[],uuid),app_private.admin_registration_scope_end(uuid),
 app_private.protect_confirmed_composition(),app_private.registration_management_composition_mail_current(uuid,text,integer),app_private.admin_registration_refresh_group(uuid,uuid),
 app_private.admin_registration_assert_group_capacity(uuid),app_private.admin_registration_group_choice(uuid),app_private.admin_registration_sync_prepared_roster(uuid) from public,anon,authenticated;
revoke all on function api.admin_registration_management_preview(text,uuid),api.admin_registration_manage_apply(text,uuid,text,jsonb,text,text,text) from public,anon;
grant execute on function api.admin_registration_management_preview(text,uuid),api.admin_registration_manage_apply(text,uuid,text,jsonb,text,text,text) to authenticated;
