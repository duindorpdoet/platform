-- One event policy, impact review and event-first serialization. Existing
-- participants, memberships, schedules and historical exceptions are retained.
set lock_timeout='5s';

-- Existing authorized together decisions can approve one exact bundle. Their
-- permission is scoped to this transaction and current configuration; it never
-- authorizes later child growth, another bundle or physical capacity overrides.
create table if not exists app_private.group_size_override_commands(
 id uuid primary key default gen_random_uuid(),event_id uuid not null references app_private.events(id),
 party_id uuid not null references app_private.together_parties(id),actor_id uuid not null references auth.users(id),
 approved_registration_ids uuid[] not null,approved_children integer not null check(approved_children>0),
 settings_version integer not null,transaction_id bigint not null default txid_current(),
 reason text not null check(char_length(reason) between 10 and 500),reviewed_at timestamptz not null default now()
);
create index if not exists group_size_override_transaction_idx on app_private.group_size_override_commands(transaction_id,party_id);
alter table app_private.group_size_override_commands enable row level security;
revoke all on app_private.group_size_override_commands from public,anon,authenticated;

create or replace function app_private.event_group_size_limit(_event uuid)
returns integer language plpgsql stable security definer set search_path='' as $$
declare value jsonb; result integer;
begin
 select settings->'maxGroupSize' into value from app_private.events where id=_event;
 if not found then raise exception 'EVENT_NOT_FOUND' using errcode='P0002'; end if;
 -- The proven legacy policy was twenty when the JSON key was absent.
 if value is null then return 20; end if;
 if jsonb_typeof(value)<>'number' or value::text !~ '^[0-9]+$'
   or value::text::numeric not between 1 and 2147483647 then
  raise exception 'INVALID_GROUP_LIMIT' using errcode='22023';
 end if;
 result:=value::text::integer;
 return result;
end $$;
revoke all on function app_private.event_group_size_limit(uuid) from public,anon,authenticated;

create or replace function app_private.validate_event_group_size_policy()
returns trigger language plpgsql set search_path='' as $$
declare maximum jsonb:=new.settings->'maxGroupSize'; target jsonb:=new.settings->'targetGroupSize';
begin
 if maximum is null then
  if tg_op='INSERT' then new.settings:=new.settings||'{"maxGroupSize":20}'::jsonb; maximum:='20';
  elsif old.settings?'maxGroupSize' then raise exception 'INVALID_GROUP_LIMIT' using errcode='22023';
  else maximum:='20'; end if;
 end if;
 if jsonb_typeof(maximum)<>'number' or maximum::text !~ '^[0-9]+$'
  or maximum::text::numeric not between 1 and 2147483647 then
  raise exception 'INVALID_GROUP_LIMIT' using errcode='22023';
 end if;
 if target is not null and (jsonb_typeof(target)<>'number' or target::text !~ '^[0-9]+$'
  or target::text::numeric<1 or target::text::numeric>maximum::text::numeric) then
  raise exception 'INVALID_TARGET_GROUP_SIZE' using errcode='22023';
 end if;
 return new;
end $$;
revoke all on function app_private.validate_event_group_size_policy() from public,anon,authenticated;
drop trigger if exists events_group_size_policy on app_private.events;
create trigger events_group_size_policy before insert or update of settings on app_private.events
 for each row execute function app_private.validate_event_group_size_policy();

create or replace function app_private.group_size_policy_impact(_event uuid,_maximum integer,_target integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e app_private.events; groups jsonb; parties jsonb; fingerprint text;
begin
 if _maximum is null or _maximum<1 or (_target is not null and (_target<1 or _target>_maximum)) then
  raise exception 'INVALID_GROUP_LIMIT' using errcode='22023';
 end if;
 select * into e from app_private.events where id=_event;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'code',coalesce(g.system_code,g.code),
  'childCount',(select count(distinct c.id) from app_private.group_registrations a
   join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active'
   where a.group_id=g.id and a.superseded_at is null),'status',g.status,'version',g.version,
  'published',exists(select 1 from app_private.group_registrations a where a.group_id=g.id and a.superseded_at is null and a.published_at is not null)) order by g.id),'[]')
 into groups from app_private.walking_groups g where g.event_id=_event;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'code',p.cluster_reference,
  'childCount',app_private.together_party_child_count(p.id),'locked',p.locked_at is not null,
  'members',coalesce((select jsonb_agg(m.registration_id order by m.registration_id) from app_private.together_memberships m where m.party_id=p.id and m.left_at is null),'[]')) order by p.id),'[]')
 into parties from app_private.together_parties p where p.event_id=_event;
 fingerprint:=encode(extensions.digest(jsonb_build_object('event',e.id,'version',e.settings_version,
  'maximum',_maximum,'target',_target,'groups',groups,'parties',parties)::text,'sha256'),'hex');
 return jsonb_build_object('settingsVersion',e.settings_version,'maxGroupSize',app_private.event_group_size_limit(e.id),
  'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,app_private.event_group_size_limit(e.id)),
  'followsMaximum',not(e.settings?'targetGroupSize'),'requestedMaximum',_maximum,'requestedTarget',coalesce(_target,_maximum),
  'impactHash',fingerprint,'groups',coalesce((select jsonb_agg(item) from jsonb_array_elements(groups) item where (item->>'childCount')::integer>_maximum),'[]'),
  'parties',coalesce((select jsonb_agg(item-'members') from jsonb_array_elements(parties) item where (item->>'childCount')::integer>_maximum),'[]'));
end $$;
revoke all on function app_private.group_size_policy_impact(uuid,integer,integer) from public,anon,authenticated;

create or replace function api.admin_group_size_policy_preview(_event_slug text,_max_group_size integer,_target_group_size integer default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e app_private.events;
begin
 select * into e from app_private.events where slug=_event_slug;
 if auth.uid() is null or e.id is null or not(app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'groups_manage',auth.uid())) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 return app_private.group_size_policy_impact(e.id,_max_group_size,_target_group_size);
end $$;
revoke all on function api.admin_group_size_policy_preview(text,integer,integer) from public,anon,authenticated;
grant execute on function api.admin_group_size_policy_preview(text,integer,integer) to authenticated;

create or replace function api.admin_group_size_policy_save(_event_slug text,_max_group_size integer,_target_group_size integer,
 _expected_settings_version integer,_expected_impact_hash text,_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; impact jsonb; old_limit integer; old_target integer; result_version integer;
begin
 select * into e from app_private.events where slug=_event_slug for update;
 if auth.uid() is null or e.id is null or not(app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'groups_manage',auth.uid())) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 if _expected_settings_version is distinct from e.settings_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if char_length(trim(coalesce(_reason,''))) not between 10 and 500 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 impact:=app_private.group_size_policy_impact(e.id,_max_group_size,_target_group_size);
 if _expected_impact_hash is distinct from impact->>'impactHash' then raise exception 'GROUP_SIZE_IMPACT_CHANGED' using errcode='40001'; end if;
 old_limit:=app_private.event_group_size_limit(e.id); old_target:=(e.settings->>'targetGroupSize')::integer;
 if old_limit=_max_group_size and old_target is not distinct from _target_group_size then return impact; end if;
 update app_private.events set settings=(settings-'targetGroupSize')||jsonb_build_object('maxGroupSize',_max_group_size)
  ||case when _target_group_size is null then '{}'::jsonb else jsonb_build_object('targetGroupSize',_target_group_size) end,
  settings_version=settings_version+1,updated_at=now() where id=e.id returning settings_version into result_version;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(e.id,auth.uid(),'group_size_limit.updated','event',e.id,jsonb_build_object('from',old_limit,'to',_max_group_size,
  'previousTarget',old_target,'target',_target_group_size,'settingsVersion',result_version,'reason',trim(_reason),
  'existingGroups',impact->'groups','existingParties',impact->'parties','reviewedImpactHash',_expected_impact_hash));
 perform realtime.send(jsonb_build_object('resource','event_settings','version',result_version),'snapshot_changed','admin-event:'||e.id::text,true);
 return jsonb_build_object('settingsVersion',result_version,'maxGroupSize',_max_group_size,
  'targetGroupSize',coalesce(_target_group_size,_max_group_size),'followsMaximum',_target_group_size is null,
  'groups',impact->'groups','parties',impact->'parties');
end $$;
revoke all on function api.admin_group_size_policy_save(text,integer,integer,integer,text,text) from public,anon,authenticated;
grant execute on function api.admin_group_size_policy_save(text,integer,integer,integer,text,text) to authenticated;

-- Older clients remain compatible for ordinary changes, but cannot bypass the
-- explicit impact review when lowering a policy below existing groups/parties.
create or replace function api.admin_set_group_size_limit(_event_slug text,_max_group_size integer,_expected_settings_version integer,_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; target integer; impact jsonb;
begin
 select * into e from app_private.events where slug=_event_slug for update;
 if auth.uid() is null or e.id is null or not(app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'groups_manage',auth.uid())) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501';
 end if;
 if _max_group_size is null or _max_group_size<1 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 if _expected_settings_version is distinct from e.settings_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 target:=(e.settings->>'targetGroupSize')::integer;
 impact:=app_private.group_size_policy_impact(e.id,_max_group_size,target);
 if _max_group_size<app_private.event_group_size_limit(e.id) and (jsonb_array_length(impact->'groups')>0 or jsonb_array_length(impact->'parties')>0) then
  raise exception 'GROUP_SIZE_IMPACT_REVIEW_REQUIRED' using errcode='23514';
 end if;
 return api.admin_group_size_policy_save(_event_slug,_max_group_size,target,_expected_settings_version,impact->>'impactHash',_reason);
end $$;

create or replace function app_private.guard_registration_draft_child_limit()
returns trigger language plpgsql security definer set search_path='' as $$
declare maximum integer; current_count integer:=0; proposed integer;
begin
 perform 1 from app_private.events where id=new.event_id for update;
 maximum:=app_private.event_group_size_limit(new.event_id);
 if jsonb_typeof(new.payload->'children')='array' then
  proposed:=jsonb_array_length(new.payload->'children');
  if tg_op='UPDATE' and old.event_id=new.event_id and jsonb_typeof(old.payload->'children')='array' then current_count:=jsonb_array_length(old.payload->'children'); end if;
  if proposed>maximum and proposed>current_count then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514',detail=jsonb_build_object('maxGroupSize',maximum,'projectedChildren',proposed)::text; end if;
 end if;
 return new;
end $$;

create or replace function app_private.enforce_twenty_child_limit()
returns trigger language plpgsql security definer set search_path='' as $$
declare total integer; before_count integer; maximum integer; eventid uuid; target uuid; old_active boolean:=false; ids uuid[];
begin
 -- Keep the trigger identity for compatibility, replace its former fixed policy.
 if tg_table_name='together_memberships' then
  if new.left_at is not null then return new; end if;
  select event_id into eventid from app_private.together_parties where id=new.party_id;
  perform 1 from app_private.events where id=eventid for update;
  perform 1 from app_private.together_parties where id=new.party_id for update;
  if not exists(select 1 from app_private.registrations r where r.id=new.registration_id and r.event_id=eventid) then raise exception 'EVENT_MISMATCH' using errcode='23514'; end if;
  select array_agg(distinct registration_id) into ids from app_private.together_memberships where party_id=new.party_id and left_at is null;
  select count(*)::integer into before_count from app_private.registration_children where registration_id=any(coalesce(ids,'{}')) and participation_status='active';
  select count(*)::integer into total from app_private.registration_children c where c.participation_status='active' and (c.registration_id=new.registration_id or c.registration_id in(select m.registration_id from app_private.together_memberships m where m.party_id=new.party_id and m.left_at is null and m.id<>new.id));
 elsif tg_table_name='group_registrations' then
  if new.superseded_at is not null then return new; end if;
  select event_id into eventid from app_private.walking_groups where id=new.group_id;
  perform 1 from app_private.events where id=eventid for update;
  perform 1 from app_private.walking_groups where id=new.group_id for update;
  if not exists(select 1 from app_private.registrations r where r.id=new.registration_id and r.event_id=eventid) then raise exception 'EVENT_MISMATCH' using errcode='23514'; end if;
  select array_agg(distinct registration_id) into ids from app_private.group_registrations where group_id=new.group_id and superseded_at is null;
  select count(*)::integer into before_count from app_private.registration_children where registration_id=any(coalesce(ids,'{}')) and participation_status='active';
  select count(*)::integer into total from app_private.registration_children c where c.participation_status='active' and (c.registration_id=new.registration_id or c.registration_id in(select a.registration_id from app_private.group_registrations a where a.group_id=new.group_id and a.superseded_at is null and a.id<>new.id));
 else
  if new.participation_status<>'active' then return new; end if;
  if tg_op='UPDATE' then old_active:=old.participation_status='active' and old.registration_id=new.registration_id; end if;
  if old_active then return new; end if;
  select event_id into eventid from app_private.registrations where id=new.registration_id;
  if new.event_id is distinct from eventid then raise exception 'EVENT_MISMATCH' using errcode='23514'; end if;
  perform 1 from app_private.events where id=eventid for update;
  maximum:=app_private.event_group_size_limit(eventid);
  perform 1 from app_private.registrations where id=new.registration_id for update;
  select count(*)::integer into before_count from app_private.registration_children where registration_id=new.registration_id and participation_status='active' and id<>new.id;
  if before_count+1>maximum then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514',detail=jsonb_build_object('maxGroupSize',maximum,'projectedChildren',before_count+1)::text; end if;
  for target in select party_id from app_private.together_memberships where registration_id=new.registration_id and left_at is null order by party_id loop
   perform 1 from app_private.together_parties where id=target for update;
   select count(distinct c.id)::integer+1 into total from app_private.registration_children c join app_private.together_memberships m on m.registration_id=c.registration_id
    where m.party_id=target and m.left_at is null and c.participation_status='active' and c.id<>new.id;
   if total>maximum then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514',detail=jsonb_build_object('maxGroupSize',maximum,'projectedChildren',total)::text; end if;
  end loop;
  for target in select group_id from app_private.group_registrations where registration_id=new.registration_id and superseded_at is null order by group_id loop
   perform 1 from app_private.walking_groups where id=target for update;
   select count(distinct c.id)::integer+1 into total from app_private.registration_children c join app_private.group_registrations a on a.registration_id=c.registration_id
    where a.group_id=target and a.superseded_at is null and c.participation_status='active' and c.id<>new.id;
   if total>maximum then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514',detail=jsonb_build_object('maxGroupSize',maximum,'projectedChildren',total)::text; end if;
  end loop;
  return new;
 end if;
 maximum:=app_private.event_group_size_limit(eventid);
 if tg_table_name='together_memberships' then
 if total>maximum and exists(
  select 1 from app_private.group_size_override_commands review join app_private.events e on e.id=review.event_id
  where review.event_id=eventid and review.party_id=new.party_id and review.transaction_id=txid_current()
   and review.actor_id=auth.uid() and review.settings_version=e.settings_version and total<=review.approved_children
   and new.registration_id=any(review.approved_registration_ids)
   and not exists(select 1 from app_private.together_memberships m where m.party_id=new.party_id and m.left_at is null
     and not(m.registration_id=any(review.approved_registration_ids)))
 ) then return new; end if;
 end if;
 if total>maximum and total>before_count then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514',detail=jsonb_build_object('maxGroupSize',maximum,'projectedChildren',total)::text; end if;
 return new;
end $$;

-- Metadata-only corrections and safe reductions above a lowered policy remain
-- possible. Ordinary growth is checked against the current event, not a token.
