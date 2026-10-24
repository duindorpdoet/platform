-- Additive, private evidence. Existing tutorial/publication/credential rows remain intact.
set lock_timeout='5s';
create table app_private.evening_readiness_evidence (
 id uuid primary key default gen_random_uuid(),
 event_id uuid not null references app_private.events(id),
 subject_type text not null check(subject_type in ('group','portal')),
 subject_id uuid not null,
 group_id uuid generated always as (case when subject_type='group' then subject_id end) stored references app_private.walking_groups(id),
 portal_id uuid generated always as (case when subject_type='portal' then subject_id end) stored references app_private.portals(id),
 check_name text not null check(check_name in ('account_opened','tutorial_completed','start_time_seen','qr_downloaded','qr_tested','ready_to_host')),
 source text not null check(source in ('observed','manual')),
 -- An immutable actor reference must not block the existing account deletion procedure.
 actor_id uuid not null,actor_label text not null,
 revision text not null,done boolean not null,detail text,
 attestations jsonb not null default '{}',
 occurred_at timestamptz not null default clock_timestamp(),
 recorded_at timestamptz not null default clock_timestamp(),
 check(char_length(coalesce(detail,''))<=1000),
 check(jsonb_typeof(attestations)='object')
);
alter table app_private.evening_readiness_evidence enable row level security;
revoke all on app_private.evening_readiness_evidence from public,anon,authenticated;
create index evening_readiness_subject on app_private.evening_readiness_evidence(event_id,subject_type,subject_id,check_name,recorded_at desc,id);
create index evening_readiness_group_fk on app_private.evening_readiness_evidence(group_id) where group_id is not null;
create index evening_readiness_portal_fk on app_private.evening_readiness_evidence(portal_id) where portal_id is not null;
create unique index evening_readiness_observed_once on app_private.evening_readiness_evidence(subject_type,subject_id,check_name,actor_id,revision) where source='observed';
create function app_private.preserve_evening_readiness() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'READINESS_EVIDENCE_IMMUTABLE' using errcode='23514'; end $$;
create trigger preserve_evening_readiness before update or delete on app_private.evening_readiness_evidence
 for each row execute function app_private.preserve_evening_readiness();

create function app_private.readiness_group_adults(_group uuid)
returns table(household_id uuid,user_id uuid) language sql stable security definer set search_path='' as $$
 select distinct r.household_id,m.user_id from app_private.walking_groups g
 join app_private.group_registrations a on a.group_id=g.id and a.superseded_at is null
 join app_private.registrations r on r.id=a.registration_id and r.event_id=g.event_id and r.status='submitted'
 join app_private.household_members m on m.household_id=r.household_id and m.revoked_at is null and m.accepted_at<=statement_timestamp()
 where g.id=_group and exists(select 1 from app_private.registration_children c where c.registration_id=r.id and c.participation_status='active')
$$;
create function app_private.readiness_own_subject(_kind text,_id uuid,_actor uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select _actor is not null and case _kind when 'group' then
   exists(select 1 from app_private.readiness_group_adults(_id) a where a.user_id=_actor)
   or app_private.is_current_leader(_id,_actor)
 when 'portal' then exists(select 1 from app_private.portal_owners o join app_private.portals p on p.id=o.portal_id
   where o.portal_id=_id and o.user_id=_actor and o.revoked_at is null and o.suspended_at is null
     and p.approval_status='approved' and p.lifecycle_status<>'archived') else false end
$$;
create function app_private.evening_readiness_revision(_kind text,_id uuid,_check text)
returns text language plpgsql stable security definer set search_path='' as $$
declare revision text; eventid uuid;
begin
 if _kind='group' then
  select event_id into eventid from app_private.walking_groups where id=_id;
  if _check='start_time_seen' then
   select 'publication:'||p.id||':'||p.revision into revision from app_private.group_start_publications p
    where p.group_id=_id order by p.publication_order desc limit 1;
  elsif _check='tutorial_completed' then revision:='tutorial:parent:1';
  elsif _check='account_opened' then revision:='account:'||eventid||':group:'||_id; end if;
 elsif _kind='portal' then
  select event_id into eventid from app_private.portals where id=_id;
  if _check in ('qr_downloaded','qr_tested','ready_to_host') then
   select 'credential:'||c.id||':'||c.version into revision from app_private.portal_credentials c
    where c.portal_id=_id and c.revoked_at is null and c.valid_from<=statement_timestamp()
      and (c.valid_until is null or c.valid_until>statement_timestamp()) order by c.version desc limit 1;
  elsif _check='tutorial_completed' then revision:='tutorial:house:1';
  elsif _check='account_opened' then revision:='account:'||eventid||':portal:'||_id; end if;
 end if;
 return case when eventid is null then null else revision end;
end $$;

create function app_private.readiness_actor_label(_kind text,_id uuid,_actor uuid)
returns text language sql stable security definer set search_path='' as $$
 select coalesce((select nullif(trim(display_name),'') from app_private.profiles where user_id=_actor),
  case when _kind='portal' then (select nullif(trim(concat_ws(' ',o.first_name,o.last_name)),'') from app_private.portal_owners o where o.portal_id=_id and o.user_id=_actor and o.revoked_at is null limit 1) end,
  case when _kind='group' and app_private.is_current_leader(_id,_actor) then 'Groepsleider' end,
  case when _kind='group' then (select 'Volwassene · '||h.label from app_private.readiness_group_adults(_id) a join app_private.households h on h.id=a.household_id where a.user_id=_actor order by h.id limit 1) end,
  case when _kind='portal' and app_private.readiness_own_subject(_kind,_id,_actor) then 'Poortteamlid' else 'Organisatie' end)
$$;

create function api.record_evening_readiness(_subject_type text,_subject_id uuid,_check text,_source text,
 _expected_revision text,_detail text,_attestations jsonb,_done boolean,_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); eventid uuid; current_revision text; own boolean; manager boolean;
 evidence app_private.evening_readiness_evidence; receipt app_private.command_receipts;
 fingerprint text; result jsonb; label text; safe_attestations jsonb:='{}'; credential app_private.portal_credentials;
 completed timestamptz; tutorial_role text; tutorial_revision text;
begin
 if actor is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _subject_type='group' then
  select event_id into eventid from app_private.walking_groups where id=_subject_id;
  tutorial_role:='parent';
 elsif _subject_type='portal' then
  select event_id into eventid from app_private.portals where id=_subject_id;
  tutorial_role:='house';
 end if;
 -- Shared event lock precedes subject locks. Multiple observations may run in
 -- parallel; route/publication writers cannot hold the event while waiting for
 -- a subject which is itself waiting on the evidence event FK.
 if eventid is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from app_private.events where id=eventid for share;
 if _subject_type='group' then perform 1 from app_private.walking_groups where id=_subject_id for share;
 else perform 1 from app_private.portals where id=_subject_id for share; end if;
 -- Recheck role after any wait on the event/subject. A revoked role must not
 -- survive as a cached authorization decision from before that wait.
 manager:=case when _subject_type='group' then
  app_private.has_capability(eventid,'groups_manage',actor) or app_private.has_capability(eventid,'live_support',actor) or app_private.has_capability(eventid,'event_admin',actor)
 else app_private.has_capability(eventid,'portals_manage',actor) or app_private.has_capability(eventid,'event_admin',actor)
  or exists(select 1 from app_private.portal_owners o where o.portal_id=_subject_id and o.user_id=actor and o.revoked_at is null and o.suspended_at is null and o.access_level='manage') end;
 own:=app_private.readiness_own_subject(_subject_type,_subject_id,actor);
 if eventid is null or _source is null or _source not in ('manual','observed')
   or (_source='observed' and not own) or (_source='manual' and not coalesce(manager,false)) then
  raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _check is null or (_subject_type='group' and _check not in ('account_opened','tutorial_completed','start_time_seen'))
  or (_subject_type='portal' and _check not in ('account_opened','tutorial_completed','qr_downloaded','qr_tested','ready_to_host'))
  or _done is null or char_length(coalesce(_idempotency_key,'')) not between 16 and 200
  or char_length(coalesce(_detail,''))>1000 or jsonb_typeof(_attestations) is distinct from 'object'
  or exists(select 1 from jsonb_object_keys(_attestations) k where k not in ('confirmed','printed','scannedWithPhone','shortCode')) then
  raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 if _source='observed' and (not _done or _check in ('qr_tested','ready_to_host') or _detail is not null or _attestations<>'{}') then
  raise exception 'OBSERVATION_NOT_ALLOWED' using errcode='22023'; end if;
 if _source='manual' and (nullif(trim(_detail),'') is null or _attestations->'confirmed' is distinct from 'true'::jsonb) then
  raise exception 'ATTESTATION_REQUIRED' using errcode='22023'; end if;
 fingerprint:=encode(extensions.digest(convert_to(jsonb_build_array(_subject_type,_subject_id,_check,_source,_expected_revision,_detail,_attestations,_done)::text,'UTF8'),'sha256'),'hex');
 perform pg_advisory_xact_lock(hashtextextended(actor||':evening.readiness:'||_idempotency_key,0));
 select * into receipt from app_private.command_receipts where actor_id=actor and command_type='evening.readiness' and idempotency_key=_idempotency_key;
 if receipt.id is not null then
  if receipt.request_hash<>fingerprint then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505'; end if;
  return receipt.safe_result;
 end if;
 current_revision:=app_private.evening_readiness_revision(_subject_type,_subject_id,_check);
 if current_revision is null then raise exception 'READINESS_REVISION_UNAVAILABLE' using errcode='23514'; end if;
 if not (_source='observed' and _check='account_opened' and _expected_revision is null)
  and _expected_revision is distinct from current_revision then raise exception 'STALE_READINESS_REVISION' using errcode='40001'; end if;
 if _source='observed' and _check='tutorial_completed' then
  select completed_at into completed from app_private.participant_tutorials where event_id=eventid and user_id=actor and role=tutorial_role and version=1;
  if completed is null then raise exception 'TUTORIAL_NOT_COMPLETED' using errcode='23514'; end if;
 end if;
 if _source='observed' and _check='qr_downloaded' and not exists(
  select 1 from app_private.portal_credentials c join app_private.portal_print_material m on m.credential_id=c.id
   where 'credential:'||c.id||':'||c.version=current_revision) then raise exception 'PRINT_MATERIAL_UNAVAILABLE' using errcode='23514'; end if;
 if _source='manual' then
  safe_attestations:=jsonb_build_object('confirmed',true);
  if _check='qr_tested' and _done then
   select * into credential from app_private.portal_credentials c where 'credential:'||c.id||':'||c.version=current_revision;
   if _attestations->'printed' is distinct from 'true'::jsonb or _attestations->'scannedWithPhone' is distinct from 'true'::jsonb
    or credential.short_code_hash is null or char_length(coalesce(_attestations->>'shortCode','')) not between 4 and 160
    or credential.short_code_hash<>extensions.digest(convert_to(upper(trim(_attestations->>'shortCode')),'UTF8'),'sha256') then
    raise exception 'PHYSICAL_QR_ATTESTATION_REQUIRED' using errcode='22023'; end if;
   safe_attestations:=safe_attestations||jsonb_build_object('printed',true,'scannedWithPhone',true,'shortCodeMatched',true);
  end if;
 end if;
 label:=app_private.readiness_actor_label(_subject_type,_subject_id,actor);
 insert into app_private.evening_readiness_evidence(event_id,subject_type,subject_id,check_name,source,actor_id,actor_label,revision,done,detail,attestations,occurred_at)
 values(eventid,_subject_type,_subject_id,_check,_source,actor,label,current_revision,_done,
  case when _source='manual' then trim(_detail) end,safe_attestations,coalesce(completed,clock_timestamp()))
 on conflict(subject_type,subject_id,check_name,actor_id,revision) where source='observed' do nothing returning * into evidence;
 if evidence.id is null then select * into evidence from app_private.evening_readiness_evidence where subject_type=_subject_type and subject_id=_subject_id and check_name=_check and actor_id=actor and revision=current_revision and source='observed'; end if;
 -- Preserve the actual completed tutorial against this own subject when it is opened.
 -- This copies proven completion, never a click by a support account.
 if own and _source='observed' and _check='account_opened' then
  select completed_at into completed from app_private.participant_tutorials where event_id=eventid and user_id=actor and role=tutorial_role and version=1;
  if completed is not null then
   tutorial_revision:='tutorial:'||tutorial_role||':1';
   insert into app_private.evening_readiness_evidence(event_id,subject_type,subject_id,check_name,source,actor_id,actor_label,revision,done,occurred_at)
    values(eventid,_subject_type,_subject_id,'tutorial_completed','observed',actor,label,tutorial_revision,true,completed)
    on conflict(subject_type,subject_id,check_name,actor_id,revision) where source='observed' do nothing;
  end if;
 end if;
 result:=jsonb_build_object('id',evidence.id,'revision',evidence.revision,'source',evidence.source,'at',evidence.occurred_at,'done',evidence.done);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(actor,'evening.readiness',_idempotency_key,fingerprint,result,now()+interval '2 days');
 return result;
end $$;

-- Read-only projection of immutable evidence plus actual pre-existing tutorial completion.
create function app_private.evening_readiness_rows(_kind text,_id uuid,_check text)
returns table(id text,source text,actor_id uuid,actor_label text,revision text,done boolean,detail text,at timestamptz,recorded_at timestamptz,current boolean)
language sql stable security definer set search_path='' as $$
 with real_rows as (
  select e.id::text,e.source,e.actor_id,e.actor_label,e.revision,e.done,e.detail,e.occurred_at at,e.recorded_at
   from app_private.evening_readiness_evidence e where e.subject_type=_kind and e.subject_id=_id and e.check_name=_check
  union all
  select 'tutorial:'||t.user_id||':'||t.role||':'||t.version,'observed',t.user_id,app_private.readiness_actor_label(_kind,_id,t.user_id),
    'tutorial:'||t.role||':'||t.version,true,null,t.completed_at,t.completed_at
   from app_private.participant_tutorials t left join app_private.profiles p on p.user_id=t.user_id
   where _check='tutorial_completed' and t.completed_at is not null
    and ((_kind='group' and t.role='parent' and exists(select 1 from app_private.walking_groups g where g.id=_id and g.event_id=t.event_id))
     or (_kind='portal' and t.role='house' and exists(select 1 from app_private.portals p where p.id=_id and p.event_id=t.event_id)))
    and app_private.readiness_own_subject(_kind,_id,t.user_id)
    and not exists(select 1 from app_private.evening_readiness_evidence e where e.subject_type=_kind and e.subject_id=_id and e.check_name=_check
     and e.source='observed' and e.actor_id=t.user_id and e.revision='tutorial:'||t.role||':'||t.version)
 ) select r.*,r.revision=app_private.evening_readiness_revision(_kind,_id,_check)
   and (r.source='manual' or app_private.readiness_own_subject(_kind,_id,r.actor_id)) from real_rows r
$$;
create function app_private.evening_readiness_criterion(_kind text,_id uuid,_check text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb; current_revision text; manual_done boolean; any_current boolean; any_old boolean; observed_complete boolean;
begin
 current_revision:=app_private.evening_readiness_revision(_kind,_id,_check);
 select jsonb_agg(jsonb_build_object('id',r.id,'source',r.source,'actorLabel',r.actor_label,'at',r.at,'detail',r.detail,'done',r.done,
   'current',r.current,'revisionLabel',case
    when _check='account_opened' then 'Eigen omgeving'
    when _check='tutorial_completed' then 'Rondleiding versie '||split_part(r.revision,':',3)
    when _check='start_time_seen' then 'Startafspraak versie '||split_part(r.revision,':',3)
    else 'QR-poster versie '||split_part(r.revision,':',3) end) order by r.recorded_at desc,r.id),
  coalesce(bool_or(r.current and r.done and r.source='observed'),false),coalesce(bool_or(not r.current),false)
 into rows,any_current,any_old from app_private.evening_readiness_rows(_kind,_id,_check) r;
 select r.done into manual_done from app_private.evening_readiness_rows(_kind,_id,_check) r where r.current and r.source='manual' order by r.recorded_at desc,r.id desc limit 1;
 if _kind='group' and exists(select 1 from app_private.readiness_group_adults(_id)) then
  observed_complete:=not exists(select 1 from app_private.readiness_group_adults(_id) a where not exists(
   select 1 from app_private.readiness_group_adults(_id) other
    join app_private.evening_readiness_rows(_kind,_id,_check) r on r.actor_id=other.user_id and r.source='observed' and r.current and r.done
   where other.household_id=a.household_id));
 else observed_complete:=any_current; end if;
 return jsonb_build_object('check',_check,'revision',current_revision,'state',case
  when manual_done=false then 'not_done' when manual_done=true or observed_complete then 'complete'
  when any_old and not any_current then 'outdated' else 'unknown' end,'evidence',coalesce(rows,'[]'));
end $$;

create function api.admin_evening_readiness(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e app_private.events; groups_allowed boolean; portals_allowed boolean; result jsonb:='[]'; subject record; checks text[]; criteria jsonb;
 households integer; observed integer; household_details jsonb;
begin
 select * into e from app_private.events where slug=_event_slug;
 groups_allowed:=app_private.has_capability(e.id,'groups_manage') or app_private.has_capability(e.id,'live_support') or app_private.has_capability(e.id,'event_admin');
 portals_allowed:=app_private.has_capability(e.id,'portals_manage') or app_private.has_capability(e.id,'event_admin');
 if auth.uid() is null or e.id is null or not(groups_allowed or portals_allowed) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 for subject in
  select g.id,'group' kind,g.system_code code,coalesce(g.display_name,g.system_code) name,'Groep · eigen volwassenen en gezinnen' detail
   from app_private.walking_groups g where groups_allowed and g.event_id=e.id and g.status not in ('cancelled')
  union all
  select p.id,'portal',p.system_code,p.name,'Poortteam · actuele QR-poster'
   from app_private.portals p where portals_allowed and p.event_id=e.id and p.approval_status='approved' and p.lifecycle_status<>'archived'
  order by kind,code,id
 loop
  checks:=case when subject.kind='group' then array['account_opened','tutorial_completed','start_time_seen'] else array['account_opened','tutorial_completed','qr_downloaded','qr_tested','ready_to_host'] end;
  select jsonb_agg(app_private.evening_readiness_criterion(subject.kind,subject.id,c) order by n) into criteria from unnest(checks) with ordinality q(c,n);
  households:=null;observed:=null;household_details:=null;
  if subject.kind='group' then
   select count(distinct a.household_id),count(distinct a.household_id) filter(where exists(
    select 1 from app_private.evening_readiness_rows('group',subject.id,'account_opened') r where r.actor_id=a.user_id and r.source='observed' and r.current and r.done))
    into households,observed from app_private.readiness_group_adults(subject.id) a;
   select coalesce(jsonb_agg(jsonb_build_object('id',h.id,'label',h.label,'checks',(
    select jsonb_agg(jsonb_build_object('check',c,'state',case when exists(
      select 1 from app_private.readiness_group_adults(subject.id) a join app_private.evening_readiness_rows('group',subject.id,c) r
        on r.actor_id=a.user_id and r.source='observed' and r.current and r.done where a.household_id=h.id)
      then 'complete' else 'unknown' end) order by n) from unnest(checks) with ordinality q(c,n))) order by h.label,h.id),'[]')
    into household_details from app_private.households h where exists(select 1 from app_private.readiness_group_adults(subject.id) a where a.household_id=h.id);
  end if;
  result:=result||jsonb_build_array(jsonb_build_object('id',subject.id,'kind',subject.kind,'code',subject.code,'name',subject.name,'detail',subject.detail,
   'householdsTotal',households,'observedHouseholds',observed,'householdDetails',household_details,'criteria',criteria));
 end loop;
 return jsonb_build_object('subjects',result,'confirmedAt',statement_timestamp());
end $$;

-- Supply the exact immutable publication revision without changing address release rules.
alter function api.group_snapshot(uuid) set schema app_private;
alter function app_private.group_snapshot(uuid) rename to group_snapshot_before_evening_readiness;
revoke all on function app_private.group_snapshot_before_evening_readiness(uuid) from public,anon,authenticated;
create function api.group_snapshot(_group_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare base jsonb;
begin
 base:=app_private.group_snapshot_before_evening_readiness(_group_id);
 return base||jsonb_build_object('readinessRevision',app_private.evening_readiness_revision('group',_group_id,'start_time_seen'));
end $$;
revoke all on function app_private.preserve_evening_readiness(),app_private.readiness_group_adults(uuid),app_private.readiness_own_subject(text,uuid,uuid),
 app_private.evening_readiness_revision(text,uuid,text),app_private.readiness_actor_label(text,uuid,uuid),app_private.evening_readiness_rows(text,uuid,text),app_private.evening_readiness_criterion(text,uuid,text) from public,anon,authenticated;
revoke all on function api.record_evening_readiness(text,uuid,text,text,text,text,jsonb,boolean,text),api.admin_evening_readiness(text),api.group_snapshot(uuid) from public,anon;
grant execute on function api.record_evening_readiness(text,uuid,text,text,text,text,jsonb,boolean,text),api.admin_evening_readiness(text),api.group_snapshot(uuid) to authenticated;
notify pgrst,'reload schema';
