-- General house information only. No child medical data or credential rotation.
set lock_timeout='5s';
create table app_private.portal_visit_information (
 portal_id uuid primary key references app_private.portals(id) on delete cascade,
 event_id uuid not null references app_private.events(id),
 information jsonb not null check(jsonb_typeof(information)='object'),
 revision integer not null default 1 check(revision>0),
 updated_at timestamptz not null default clock_timestamp(),updated_by uuid references auth.users(id) on delete set null
);
alter table app_private.portal_visit_information enable row level security;
revoke all on app_private.portal_visit_information from public,anon,authenticated;

create function app_private.normalize_visit_information(_payload jsonb)
returns jsonb language plpgsql immutable set search_path='' as $$
declare key text; normalized jsonb;
begin
 if jsonb_typeof(_payload) is distinct from 'object' or pg_column_size(_payload)>16384
  or exists(select 1 from jsonb_object_keys(_payload) k where k not in ('warningDisclosure','warnings','warningNotes','accessibility','accessibilityNotes'))
  or jsonb_typeof(_payload->'warningDisclosure') is distinct from 'string'
  or _payload->>'warningDisclosure' not in ('unknown','none','listed')
  or jsonb_typeof(_payload->'warnings') is distinct from 'object'
  or (select count(*) from jsonb_object_keys(_payload->'warnings'))<>5
  or exists(select 1 from jsonb_object_keys(_payload->'warnings') k where k not in ('smoke','flashes','sound','actors','allergens'))
  or jsonb_typeof(_payload->'warningNotes') is distinct from 'string'
  or jsonb_typeof(_payload->'accessibility') is distinct from 'string'
  or jsonb_typeof(_payload->'accessibilityNotes') is distinct from 'string'
  or _payload->>'accessibility' not in ('','step_free','steps','mixed','unknown')
  or char_length(_payload->>'warningNotes')>500 or char_length(_payload->>'accessibilityNotes')>500 then
  raise exception 'INVALID_VISIT_INFORMATION' using errcode='22023'; end if;
 foreach key in array array['smoke','flashes','sound','actors','allergens'] loop
  if jsonb_typeof(_payload->'warnings'->key) is distinct from 'boolean'
   or (_payload->>'warningDisclosure'='none' and _payload->'warnings'->key='true'::jsonb) then
   raise exception 'INVALID_VISIT_INFORMATION' using errcode='22023'; end if;
 end loop;
 normalized:=_payload||jsonb_build_object('warningNotes',trim(_payload->>'warningNotes'),'accessibilityNotes',trim(_payload->>'accessibilityNotes'));
 return normalized;
end $$;
create function app_private.visit_information_fields(_draft jsonb)
returns jsonb language sql immutable set search_path='' as $$
 select jsonb_build_object('warningDisclosure',_draft->'warningDisclosure','warnings',_draft->'warnings',
  'warningNotes',coalesce(_draft->'warningNotes','""'),'accessibility',coalesce(_draft->'accessibility','""'),'accessibilityNotes',coalesce(_draft->'accessibilityNotes','""'))
$$;
create function app_private.portal_visit_information_value(_portal uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p app_private.portals; draft jsonb; info jsonb; warnings jsonb; access text; notes text;
begin
 select information into info from app_private.portal_visit_information where portal_id=_portal;
 if info is not null then return info; end if;
 select * into p from app_private.portals where id=_portal;
 if p.id is null then return null; end if;
 select private_draft_data into draft from app_private.portal_applications where id=p.application_id;
 -- Old false defaults are not explicit declarations. Preserve only known positives.
 select jsonb_object_agg(k,coalesce(draft->'warnings'->k='true'::jsonb,false) or exists(
  select 1 from app_private.portal_flags f where f.portal_id=p.id and f.flag_key=k and f.value)) into warnings
 from unnest(array['smoke','flashes','sound','actors','allergens']) q(k);
 access:=case when draft->>'accessibility' in ('step_free','steps','mixed','unknown') then draft->>'accessibility'
  when p.accessibility_notes in ('step_free','steps','mixed','unknown') then p.accessibility_notes else '' end;
 notes:=coalesce(nullif(draft->>'accessibilityNotes',''),case when p.accessibility_notes not in ('step_free','steps','mixed','unknown') then p.accessibility_notes end,'');
 return jsonb_build_object('warningDisclosure','unknown','warnings',warnings,'warningNotes',coalesce(draft->>'warningNotes',''),
  'accessibility',access,'accessibilityNotes',notes);
end $$;
create function app_private.portal_visit_information_projection(_portal uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare info jsonb; warnings jsonb;
begin
 info:=app_private.portal_visit_information_value(_portal);
 if info->>'warningDisclosure'='none' then warnings:=info->'warnings';
 elsif info->>'warningDisclosure'='listed' and exists(select 1 from jsonb_each(info->'warnings') q where q.value='true'::jsonb) then warnings:=info->'warnings';
 else select jsonb_object_agg(key,value) into warnings from jsonb_each(info->'warnings') where value='true'::jsonb; end if;
 return info||jsonb_build_object('warnings',warnings);
end $$;
create function app_private.write_portal_visit_information(_portal uuid,_information jsonb)
returns integer language plpgsql security definer set search_path='' as $$
declare p app_private.portals; next_revision integer; info jsonb;
begin
 info:=app_private.normalize_visit_information(_information);
 select * into p from app_private.portals where id=_portal;
 if p.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 insert into app_private.portal_visit_information(portal_id,event_id,information,updated_by)
 values(p.id,p.event_id,info,auth.uid()) on conflict(portal_id) do update set information=excluded.information,
  revision=app_private.portal_visit_information.revision+1,updated_at=clock_timestamp(),updated_by=auth.uid()
 returning revision into next_revision;
 update app_private.portals set accessibility_notes=nullif(info->>'accessibilityNotes','') where id=p.id;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(p.event_id,auth.uid(),'portal.visit_information_updated','portal',p.id,jsonb_build_object('informationRevision',next_revision,
  'warningDisclosure',info->>'warningDisclosure','accessibility',info->>'accessibility'));
 perform realtime.send(jsonb_build_object('resource','portal','id',p.id),'snapshot_changed',app_private.poortkamer_portal_topic(p.id),true);
 perform realtime.send(jsonb_build_object('resource','portal','id',p.id),'snapshot_changed','admin-event:'||p.event_id,true);
 return next_revision;
end $$;
create function api.portal_visit_information(_portal_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p app_private.portals;
begin
 perform app_private.poortkamer_require(_portal_id,'read');
 select * into p from app_private.portals where id=_portal_id;
 if p.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return jsonb_build_object('information',app_private.portal_visit_information_value(p.id),'version',p.version);
end $$;
create function api.portal_visit_information_save(_portal_id uuid,_expected_version integer,_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p app_private.portals; eventid uuid; info jsonb;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select event_id into eventid from app_private.portals where id=_portal_id;
 perform 1 from app_private.events where id=eventid for no key update;
 perform pg_advisory_xact_lock(hashtextextended(eventid||':route-dispatch',0));
 perform app_private.poortkamer_require(_portal_id,'details');
 select * into p from app_private.portals where id=_portal_id for update;
 if p.id is null or p.lifecycle_status='archived' then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 info:=app_private.normalize_visit_information(_payload);
 perform app_private.write_portal_visit_information(p.id,info);
 update app_private.portals set version=version+1,updated_at=now() where id=p.id returning * into p;
 return jsonb_build_object('version',p.version);
end $$;

-- Organization editing already checks event, role and the portal version. Keep one atomic command.
alter function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) set schema app_private;
alter function app_private.admin_manual_portal_save(text,uuid,jsonb,integer,text) rename to admin_manual_portal_save_before_visit_information;
revoke all on function app_private.admin_manual_portal_save_before_visit_information(text,uuid,jsonb,integer,text) from public,anon,authenticated;
create function api.admin_manual_portal_save(_event_slug text,_portal_id uuid,_payload jsonb,_expected_version integer,_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; info jsonb; eventid uuid;
begin
 select id into eventid from app_private.events where slug=_event_slug;
 if auth.uid() is null or not (app_private.has_capability(eventid,'portals_manage') or app_private.has_capability(eventid,'event_admin')) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _payload ? 'visitInformation' then info:=app_private.normalize_visit_information(_payload->'visitInformation'); end if;
 result:=app_private.admin_manual_portal_save_before_visit_information(_event_slug,_portal_id,_payload,_expected_version,_reason);
 if info is null and _payload ? 'accessibilityNotes' and exists(select 1 from app_private.portal_visit_information where portal_id=(result->>'id')::uuid) then
  info:=app_private.portal_visit_information_value((result->>'id')::uuid);
  if coalesce(_payload->>'accessibilityNotes','') is distinct from info->>'accessibilityNotes' then
   info:=info||jsonb_build_object('accessibilityNotes',coalesce(_payload->>'accessibilityNotes',''));
  else info:=null; end if;
 end if;
 if info is not null then perform app_private.write_portal_visit_information((result->>'id')::uuid,info); end if;
 return result;
end $$;

-- Intake uses its own application version and an information revision. Old clients
-- which omit the new declaration cannot overwrite independently edited live information.
alter function api.portal_application_save(text,jsonb,integer) set schema app_private;
alter function app_private.portal_application_save(text,jsonb,integer) rename to portal_application_save_before_visit_information;
revoke all on function app_private.portal_application_save_before_visit_information(text,jsonb,integer) from public,anon,authenticated;
create function api.portal_application_save(_event_slug text,_payload jsonb,_expected_version integer default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare eventid uuid; application_id uuid; portalid uuid; current_revision integer:=0; result jsonb; info jsonb;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select id into eventid from app_private.events where slug=_event_slug for no key update;
 perform pg_advisory_xact_lock(hashtextextended(eventid||':route-dispatch',0));
 select a.id,p.id into application_id,portalid from app_private.portal_applications a
 left join app_private.portals p on p.application_id=a.id
 where a.event_id=eventid and a.applicant_user_id=auth.uid()
 order by (a.review_status not in ('withdrawn','rejected')) desc,a.created_at desc limit 1;
 if _payload ? 'warningDisclosure' then
  info:=app_private.normalize_visit_information(app_private.visit_information_fields(_payload));
  if portalid is not null then
   perform app_private.poortkamer_require(portalid,'details');
   select coalesce((select revision from app_private.portal_visit_information where portal_id=portalid),0) into current_revision;
   if jsonb_typeof(_payload->'visitInformationRevision') is distinct from 'number'
    or _payload->>'visitInformationRevision' !~ '^[0-9]+$' or (_payload->>'visitInformationRevision')::numeric<>current_revision then
    raise exception 'STALE_VISIT_INFORMATION' using errcode='40001'; end if;
  end if;
  _payload:=_payload||info;
 end if;
 result:=app_private.portal_application_save_before_visit_information(_event_slug,_payload,_expected_version);
 if info is not null and portalid is not null then
  -- The shared event mutex precedes all portal updates in these new write paths.
  perform 1 from app_private.portals where id=portalid for update;
  current_revision:=app_private.write_portal_visit_information(portalid,info);
  update app_private.portals set version=version+1,updated_at=now() where id=portalid;
  update app_private.portal_applications set private_draft_data=private_draft_data||jsonb_build_object('visitInformationRevision',current_revision)
   where id=(result->>'id')::uuid;
 end if;
 return result||jsonb_build_object('visitInformationRevision',current_revision);
end $$;

-- Approval initializes new portals only. Existing canonical information was already
-- atomically saved by the owner; reapproval of an older application cannot replace it.
alter function api.admin_review_portal_application(uuid,integer,text,text,numeric,numeric,text) set schema app_private;
alter function app_private.admin_review_portal_application(uuid,integer,text,text,numeric,numeric,text) rename to admin_review_portal_application_before_visit_information;
revoke all on function app_private.admin_review_portal_application_before_visit_information(uuid,integer,text,text,numeric,numeric,text) from public,anon,authenticated;
create function api.admin_review_portal_application(_application_id uuid,_expected_version integer,_decision text,_world_slug text,_latitude numeric,_longitude numeric,_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare eventid uuid; result jsonb; portalid uuid; draft jsonb;
begin
 select event_id into eventid from app_private.portal_applications where id=_application_id;
 if auth.uid() is null or not app_private.has_capability(eventid,'portals_manage') then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from app_private.events where id=eventid for no key update;
 perform pg_advisory_xact_lock(hashtextextended(eventid||':route-dispatch',0));
 result:=app_private.admin_review_portal_application_before_visit_information(_application_id,_expected_version,_decision,_world_slug,_latitude,_longitude,_reason);
 if _decision='approved' then
  select p.id,a.private_draft_data into portalid,draft from app_private.portals p join app_private.portal_applications a on a.id=p.application_id where a.id=_application_id;
  if portalid is not null and draft ? 'warningDisclosure' and not exists(select 1 from app_private.portal_visit_information where portal_id=portalid) then
   perform app_private.write_portal_visit_information(portalid,app_private.visit_information_fields(draft));
  end if;
 end if;
 return result;
end $$;

alter function api.portal_snapshot(text) set schema app_private;
alter function app_private.portal_snapshot(text) rename to portal_snapshot_before_visit_information;
revoke all on function app_private.portal_snapshot_before_visit_information(text) from public,anon,authenticated;
create function api.portal_snapshot(_event_slug text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare base jsonb; pid uuid; info jsonb; revision integer;
begin
 base:=app_private.portal_snapshot_before_visit_information(_event_slug);
 pid:=(base#>>'{portal,id}')::uuid;
 if pid is null then return base; end if;
 perform app_private.poortkamer_require(pid,'read');
 info:=app_private.portal_visit_information_value(pid);
 select coalesce((select v.revision from app_private.portal_visit_information v where v.portal_id=pid),0) into revision;
 base:=jsonb_set(base,'{portal}',base->'portal'||jsonb_build_object('visitInformation',info));
 return jsonb_set(base,'{application,draft}',coalesce(base#>'{application,draft}','{}')||info||jsonb_build_object('visitInformationRevision',revision));
end $$;

alter function api.admin_portal_editor_snapshot(text) set schema app_private;
alter function app_private.admin_portal_editor_snapshot(text) rename to admin_portal_editor_snapshot_before_visit_information;
revoke all on function app_private.admin_portal_editor_snapshot_before_visit_information(text) from public,anon,authenticated;
create function api.admin_portal_editor_snapshot(_event_slug text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare base jsonb;
begin
 base:=app_private.admin_portal_editor_snapshot_before_visit_information(_event_slug);
 return jsonb_set(base,'{portals}',coalesce((select jsonb_agg(item||jsonb_build_object('visitInformation',app_private.portal_visit_information_value((item->>'id')::uuid),'accessibilityNotes',app_private.portal_visit_information_value((item->>'id')::uuid)->>'accessibilityNotes') order by n)
  from jsonb_array_elements(base->'portals') with ordinality q(item,n)),'[]'));
end $$;
alter function api.admin_portal_management_snapshot(text) set schema app_private;
alter function app_private.admin_portal_management_snapshot(text) rename to admin_portal_management_snapshot_before_visit_information;
revoke all on function app_private.admin_portal_management_snapshot_before_visit_information(text) from public,anon,authenticated;
create function api.admin_portal_management_snapshot(_event_slug text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare base jsonb;
begin
 base:=app_private.admin_portal_management_snapshot_before_visit_information(_event_slug);
 return jsonb_set(base,'{registrations}',coalesce((select jsonb_agg(case when item->>'portalId' is null then item else
  item||jsonb_build_object('draft',coalesce(item->'draft','{}')||app_private.portal_visit_information_value((item->>'portalId')::uuid)
   ||jsonb_build_object('visitInformationRevision',coalesce((select revision from app_private.portal_visit_information where portal_id=(item->>'portalId')::uuid),0))) end order by n)
  from jsonb_array_elements(base->'registrations') with ordinality q(item,n)),'[]'));
end $$;

-- Call the existing authorization/address-release projection first. Enrich only its
-- already released current portal, never a candidate, future stop or first address.
alter function api.group_snapshot(uuid) set schema app_private;
alter function app_private.group_snapshot(uuid) rename to group_snapshot_before_visit_information;
revoke all on function app_private.group_snapshot_before_visit_information(uuid) from public,anon,authenticated;
create function api.group_snapshot(_group_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare base jsonb; pid uuid;
begin
 base:=app_private.group_snapshot_before_visit_information(_group_id);
 pid:=(base#>>'{run,currentStop,portal,id}')::uuid;
 if pid is null then return base; end if;
 return jsonb_set(base,'{run,currentStop,portal}',base#>'{run,currentStop,portal}'||app_private.portal_visit_information_projection(pid));
end $$;

revoke all on function app_private.normalize_visit_information(jsonb),app_private.visit_information_fields(jsonb),app_private.portal_visit_information_value(uuid),
 app_private.portal_visit_information_projection(uuid),app_private.write_portal_visit_information(uuid,jsonb) from public,anon,authenticated;
revoke all on function api.portal_visit_information(uuid),api.portal_visit_information_save(uuid,integer,jsonb),api.admin_manual_portal_save(text,uuid,jsonb,integer,text),
 api.portal_application_save(text,jsonb,integer),api.admin_review_portal_application(uuid,integer,text,text,numeric,numeric,text),api.portal_snapshot(text),
 api.admin_portal_editor_snapshot(text),api.admin_portal_management_snapshot(text),api.group_snapshot(uuid) from public,anon;
grant execute on function api.portal_visit_information(uuid),api.portal_visit_information_save(uuid,integer,jsonb),api.admin_manual_portal_save(text,uuid,jsonb,integer,text),
 api.portal_application_save(text,jsonb,integer),api.admin_review_portal_application(uuid,integer,text,text,numeric,numeric,text),api.portal_snapshot(text),
 api.admin_portal_editor_snapshot(text),api.admin_portal_management_snapshot(text),api.group_snapshot(uuid) to authenticated;
notify pgrst,'reload schema';
