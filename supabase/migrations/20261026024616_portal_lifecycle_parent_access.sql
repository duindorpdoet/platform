-- Intake/application commands deliberately never modify household or registration records.
alter table app_private.portal_registration_intakes add column withdrawn_at timestamptz;
alter table app_private.portal_registration_intakes add column withdrawal_reason text;

create function api.admin_portal_registration_preview(_event_slug text,_kind text,_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare eid uuid; i app_private.portal_registration_intakes; a app_private.portal_applications;
 p app_private.portals; impact jsonb := '{}'::jsonb; body jsonb;
begin
 select id into eid from app_private.events where slug=_event_slug;
 if auth.uid() is null or eid is null or not app_private.has_capability(eid,'portals_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _kind='intake' then
  select * into i from app_private.portal_registration_intakes where id=_id and event_id=eid;
  select * into a from app_private.portal_applications where id=i.application_id;
 elsif _kind='application' then
  select * into a from app_private.portal_applications where id=_id and event_id=eid;
  select * into i from app_private.portal_registration_intakes where application_id=a.id;
 else raise exception 'INVALID_INPUT' using errcode='22023'; end if;
 if i.id is null and a.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into p from app_private.portals where application_id=a.id;
 if p.id is not null then impact:=api.admin_portal_change_impact(p.id); end if;
 body:=jsonb_build_object('kind',_kind,'id',_id,'intakeId',i.id,'applicationId',a.id,'portalId',p.id,
  'code',coalesce(p.system_code,a.system_code,i.system_code),'version',coalesce(a.version,i.version),
  'withdrawn',i.withdrawn_at is not null or a.review_status='withdrawn',
  'email',coalesce(i.normalized_email,a.private_draft_data->>'email'),
  'draft',coalesce(a.private_draft_data,jsonb_build_object('contactName',i.contact_name,'phone',i.phone,'address',i.private_address)),
  'impact',impact,'intakeVersion',i.version,'applicationVersion',a.version,'portalVersion',p.version);
 return body||jsonb_build_object('inputHash',md5(body::text));
end $$;

create function api.admin_portal_registration_apply(_event_slug text,_kind text,_id uuid,_action text,_payload jsonb,_input_hash text,_reason text,_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; preview jsonb; saved app_private.command_receipts; hashed text; result jsonb; iid uuid; aid uuid; pid uuid;
begin
 select id into eid from app_private.events where slug=_event_slug for no key update;
 if auth.uid() is null or eid is null or not app_private.has_capability(eid,'portals_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _action not in ('edit','withdraw') or length(trim(coalesce(_reason,''))) not between 10 and 500
  or length(coalesce(_idempotency_key,'')) not between 16 and 200 or jsonb_typeof(_payload) is distinct from 'object' or pg_column_size(_payload)>16384 then raise exception 'INVALID_INPUT' using errcode='22023'; end if;
 hashed:=md5(jsonb_build_array(_event_slug,_kind,_id,_action,_payload,_input_hash,_reason)::text);
 select * into saved from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.registration' and idempotency_key=_idempotency_key;
 if saved.id is not null then if saved.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return saved.safe_result; end if;
 perform pg_advisory_xact_lock(hashtextextended(eid::text||':route-dispatch',0));
 preview:=api.admin_portal_registration_preview(_event_slug,_kind,_id);
 if preview->>'inputHash' is distinct from _input_hash then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 iid:=(preview->>'intakeId')::uuid;aid:=(preview->>'applicationId')::uuid;pid:=(preview->>'portalId')::uuid;
 if _action='withdraw' then
  if pid is not null and exists(select 1 from app_private.portals where id=pid and lifecycle_status<>'archived') then
   perform api.admin_manual_portal_remove(pid,(preview->>'portalVersion')::integer,_reason);
  end if;
  update app_private.portal_registration_intakes set withdrawn_at=coalesce(withdrawn_at,clock_timestamp()),withdrawal_reason=_reason,version=version+1 where id=iid;
  update app_private.portal_applications set review_status='withdrawn',review_feedback=_reason,reviewed_by=auth.uid(),reviewed_at=clock_timestamp(),version=version+1 where id=aid;
  update app_private.portal_owners set revoked_at=coalesce(revoked_at,clock_timestamp()) where portal_id=pid and revoked_at is null;
  update app_private.portal_team_invites set revoked_at=clock_timestamp() where portal_id=pid and accepted_at is null and revoked_at is null;
 else
  -- Operational portal details retain their dedicated, impact-checked editor.
  if pid is not null then raise exception 'USE_PORTAL_EDITOR' using errcode='23514'; end if;
  if exists(select 1 from jsonb_object_keys(_payload) k where k not in ('contactName','phone','address','portalName','description','requestedWorldSlug','availableFrom','availableUntil','accessibility','intensity','entrance')) then raise exception 'INVALID_INPUT'; end if;
  if _payload ? 'address' and jsonb_typeof(_payload->'address')<>'object' then raise exception 'INVALID_INPUT'; end if;
  update app_private.portal_registration_intakes set contact_name=coalesce(_payload->>'contactName',contact_name),phone=coalesce(_payload->>'phone',phone),private_address=coalesce(_payload->'address',private_address),version=version+1 where id=iid;
  update app_private.portal_applications set private_draft_data=private_draft_data||_payload,version=version+1 where id=aid;
 end if;
 result:=jsonb_build_object('id',_id,'action',_action,'ordinaryRegistrationPreserved',true);
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(eid,auth.uid(),'portal.registration.'||_action,_kind,_id,jsonb_build_object('reason',_reason,'intakeId',iid,'applicationId',aid,'portalId',pid));
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(auth.uid(),'portal.registration',_idempotency_key,hashed,result,now()+interval '7 days');
 perform realtime.send(jsonb_build_object('resource','portal_registration'),'snapshot_changed','admin-event:'||eid,true);
 return result;
end $$;
revoke all on function api.admin_portal_registration_preview(text,text,uuid),api.admin_portal_registration_apply(text,text,uuid,text,jsonb,text,text,text) from public,anon;
grant execute on function api.admin_portal_registration_preview(text,text,uuid),api.admin_portal_registration_apply(text,text,uuid,text,jsonb,text,text,text) to authenticated;

-- Intercept old OTP callbacks and stale save requests at the authoritative boundary.
alter function api.portal_registration_claim(text) rename to portal_registration_claim_before_lifecycle;
revoke all on function api.portal_registration_claim_before_lifecycle(text) from public,anon,authenticated;
create function api.portal_registration_claim(_event_slug text) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid;
begin
 select id into eid from app_private.events where slug=_event_slug for no key update;
 if exists(select 1 from app_private.portal_registration_intakes i join auth.users u on lower(u.email)=i.normalized_email and u.id=auth.uid() where i.event_id=eid and i.withdrawn_at is not null)
 or exists(select 1 from app_private.portal_applications a where a.event_id=eid and a.applicant_user_id=auth.uid() and a.review_status='withdrawn' and not exists(select 1 from app_private.portal_applications b where b.event_id=eid and b.applicant_user_id=auth.uid() and b.review_status not in ('withdrawn','rejected'))) then raise exception 'PORTAL_REGISTRATION_WITHDRAWN' using errcode='23514'; end if;
 return api.portal_registration_claim_before_lifecycle(_event_slug);
end $$;
revoke all on function api.portal_registration_claim(text) from public,anon;
grant execute on function api.portal_registration_claim(text) to authenticated;

alter function api.portal_application_save(text,jsonb,integer) rename to portal_application_save_before_lifecycle;
revoke all on function api.portal_application_save_before_lifecycle(text,jsonb,integer) from public,anon,authenticated;
create function api.portal_application_save(_event_slug text,_payload jsonb,_expected_version integer default null) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform 1 from app_private.events where slug=_event_slug for no key update;
 if exists(select 1 from app_private.portal_registration_intakes i join app_private.events e on e.id=i.event_id join auth.users u on lower(u.email)=i.normalized_email and u.id=auth.uid() where e.slug=_event_slug and i.withdrawn_at is not null) then raise exception 'PORTAL_REGISTRATION_WITHDRAWN' using errcode='23514'; end if;
 return api.portal_application_save_before_lifecycle(_event_slug,_payload,_expected_version);
end $$;
revoke all on function api.portal_application_save(text,jsonb,integer) from public,anon;
grant execute on function api.portal_application_save(text,jsonb,integer) to authenticated;

-- A deliberate authenticated restart is available only for an unused application.
create function api.portal_registration_restart(_event_slug text) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; i app_private.portal_registration_intakes;
begin
 select id into eid from app_private.events where slug=_event_slug and coalesce((settings->>'portalRegistrationOpen')::boolean,false) for no key update;
 if auth.uid() is null or eid is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select intake.* into i from app_private.portal_registration_intakes intake join auth.users u on lower(u.email)=intake.normalized_email and u.id=auth.uid() and u.email_confirmed_at is not null where intake.event_id=eid and intake.withdrawn_at is not null for update of intake;
 if i.id is null then raise exception 'NO_WITHDRAWN_INTAKE'; end if;
 if exists(select 1 from app_private.portals where application_id=i.application_id) then raise exception 'CONTACT_ORGANIZATION_TO_REACTIVATE_PORTAL'; end if;
 update app_private.portal_applications set review_status='draft',review_feedback=null,version=version+1 where id=i.application_id;
 update app_private.portal_registration_intakes set withdrawn_at=null,withdrawal_reason=null,version=version+1 where id=i.id;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(eid,auth.uid(),'portal.registration.restarted','portal_intake',i.id,'{}');
 return api.portal_registration_claim_before_lifecycle(_event_slug);
end $$;
revoke all on function api.portal_registration_restart(text) from public,anon;
grant execute on function api.portal_registration_restart(text) to authenticated;

-- Refresh role projection without touching independent adult/household permissions.
alter function api.participant_context(text) rename to participant_context_before_lifecycle;
revoke all on function api.participant_context_before_lifecycle(text) from public,anon,authenticated;
create function api.participant_context(_event_slug text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 result:=api.participant_context_before_lifecycle(_event_slug);
 return jsonb_set(result,'{roles}',coalesce((select jsonb_agg(t.role order by t.ord) from jsonb_array_elements(result->'roles') with ordinality t(role,ord)
 where t.role->>'key'<>'homeowner' or exists(select 1 from app_private.portals p join app_private.portal_owners o on o.portal_id=p.id and o.user_id=auth.uid() and o.revoked_at is null and o.suspended_at is null where p.id=(t.role->>'portalId')::uuid and p.lifecycle_status<>'archived' and p.approval_status<>'withdrawn')),'[]'::jsonb));
end $$;
revoke all on function api.participant_context(text) from public,anon;
grant execute on function api.participant_context(text) to authenticated;

alter function api.portal_registration_begin(text,text,text,text,text,text,text,text,text) rename to portal_registration_begin_before_lifecycle;
revoke all on function api.portal_registration_begin_before_lifecycle(text,text,text,text,text,text,text,text,text) from public,anon,authenticated;
create function api.portal_registration_begin(_event_slug text,_email text,_contact_name text,_phone text,_street text,_house_number text,_addition text,_postal_code text,_opaque_subject_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform 1 from app_private.events where slug=_event_slug for no key update;
 if exists(select 1 from app_private.portal_registration_intakes i join app_private.events e on e.id=i.event_id where e.slug=_event_slug and i.normalized_email=lower(trim(_email)) and i.withdrawn_at is not null) then raise exception 'PORTAL_REGISTRATION_WITHDRAWN' using errcode='23514'; end if;
 return api.portal_registration_begin_before_lifecycle(_event_slug,_email,_contact_name,_phone,_street,_house_number,_addition,_postal_code,_opaque_subject_hash);
end $$;
revoke all on function api.portal_registration_begin(text,text,text,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function api.portal_registration_begin(text,text,text,text,text,text,text,text,text) to service_role;

alter function api.admin_portal_management_snapshot(text) rename to admin_portal_management_snapshot_before_lifecycle;
revoke all on function api.admin_portal_management_snapshot_before_lifecycle(text) from public,anon,authenticated;
create function api.admin_portal_management_snapshot(_event_slug text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 result:=api.admin_portal_management_snapshot_before_lifecycle(_event_slug);
 return jsonb_set(result,'{registrations}',coalesce((select jsonb_agg(item||jsonb_build_object('intakeVersion',i.version,'intakeWithdrawn',i.withdrawn_at is not null,'status',case when i.withdrawn_at is not null then 'closed' else item->>'status' end) order by ord)
 from jsonb_array_elements(result->'registrations') with ordinality t(item,ord) left join app_private.portal_registration_intakes i on i.id=(item->>'intakeId')::uuid),'[]'::jsonb));
end $$;
revoke all on function api.admin_portal_management_snapshot(text) from public,anon;
grant execute on function api.admin_portal_management_snapshot(text) to authenticated;

CREATE OR REPLACE FUNCTION app_private.participant_context_before_start_ops(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  assigned_start timestamptz;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug;
  if event_record.id is null then return null; end if;
  select slot.starts_at into assigned_start
  from (
    select leader.group_id, 0 as priority
    from app_private.group_leaders leader
    join app_private.walking_groups walking_group on walking_group.id = leader.group_id
    where walking_group.retired_at is null and walking_group.event_id = event_record.id and leader.user_id = actor
      and leader.active_from <= now() and (leader.active_until is null or leader.active_until > now())
    union all
    select assignment.group_id, 1
    from app_private.household_members member
    join app_private.registrations registration on registration.household_id = member.household_id
      and registration.event_id = event_record.id and registration.status <> 'cancelled'
    join app_private.group_registrations assignment on assignment.registration_id = registration.id and assignment.superseded_at is null
    where member.user_id = actor and member.revoked_at is null
  ) membership
  join app_private.walking_groups walking_group on walking_group.id = membership.group_id
  left join app_private.group_schedule_revisions schedule
    on schedule.group_id = walking_group.id and schedule.state = 'published'
  join app_private.start_slots slot
    on slot.id = case when walking_group.route_mode = 'dynamic' then schedule.start_slot_id else walking_group.start_slot_id end
  left join app_private.route_plan_versions plan on plan.id = walking_group.current_plan_version_id
  where (walking_group.route_mode = 'dynamic' and schedule.id is not null)
     or (walking_group.route_mode = 'legacy' and plan.state = 'published')
  order by membership.priority limit 1;

  return jsonb_build_object(
    'event', jsonb_build_object(
      'id', event_record.id, 'title', event_record.title, 'localDate', event_record.local_date,
      'phase', event_record.phase,
      'startsAt', coalesce(assigned_start, (select first_start_at from app_private.event_route_settings where event_id = event_record.id)),
      'paymentDeadline', (event_record.local_date - 1),
      'supportEmail', coalesce(nullif(event_record.settings ->> 'supportEmail', ''), 'organisatie@duindorpdoet.nl'),
      'supportPhone', nullif(event_record.settings ->> 'supportPhone', '')
    ),
    'roles', coalesce((
      select jsonb_agg(role_record.payload order by role_record.sort_order)
      from (
        select 1 as sort_order, jsonb_build_object(
          'key', 'walker', 'label', 'Meeloper',
          'groupId', (
            select membership.group_id from (
              select leader.group_id, 0 as priority
              from app_private.group_leaders leader
              join app_private.walking_groups walking_group on walking_group.id = leader.group_id
              where walking_group.retired_at is null and walking_group.event_id = event_record.id and leader.user_id = actor
                and leader.active_from <= now() and (leader.active_until is null or leader.active_until > now())
              union all
              select assignment.group_id, 1
              from app_private.household_members member
              join app_private.registrations registration on registration.household_id = member.household_id
                and registration.event_id = event_record.id and registration.status <> 'cancelled'
              join app_private.group_registrations assignment on assignment.registration_id = registration.id and assignment.superseded_at is null
              where member.user_id = actor and member.revoked_at is null
            ) membership order by membership.priority limit 1
          )
        ) as payload
        where exists (
          select 1 from app_private.household_members member
          join app_private.registrations registration on registration.household_id = member.household_id
          where member.user_id = actor and member.revoked_at is null
            and registration.event_id = event_record.id and registration.status <> 'cancelled'
        ) or exists (
          select 1 from app_private.group_leaders leader
          join app_private.walking_groups walking_group on walking_group.id = leader.group_id
          where walking_group.retired_at is null and walking_group.event_id = event_record.id and leader.user_id = actor
            and leader.active_from <= now() and (leader.active_until is null or leader.active_until > now())
        )
        union all
        select 2, jsonb_build_object(
          'key', 'viewer', 'label', 'Meekijker', 'accessId', access.id,
          'groupId', access.group_id, 'expiresAt', access.expires_at
        ) from (
          select candidate.* from app_private.group_viewer_access candidate
          where candidate.event_id = event_record.id and candidate.user_id = actor and candidate.revoked_at is null
            and (candidate.expires_at is null or candidate.expires_at > now())
          order by candidate.created_at limit 1
        ) access
        union all
        select 3, jsonb_build_object('key', 'homeowner', 'label', 'Huiseigenaar', 'portalId', portal.id)
        from (
          select candidate.* from app_private.portal_owners candidate
          join app_private.portals owned_portal on owned_portal.id = candidate.portal_id
          where owned_portal.event_id = event_record.id and candidate.user_id = actor and candidate.revoked_at is null and candidate.suspended_at is null and owned_portal.lifecycle_status <> 'archived' and owned_portal.approval_status <> 'withdrawn'
          order by candidate.accepted_at limit 1
        ) owner join app_private.portals portal on portal.id = owner.portal_id
      ) role_record
    ), '[]'::jsonb),
    'preferences', coalesce((
      select jsonb_build_object('reducedMotion', preference.reduced_motion, 'readableMode', preference.readable_mode)
      from app_private.participant_preferences preference
      where preference.event_id = event_record.id and preference.user_id = actor
    ), jsonb_build_object('reducedMotion', false, 'readableMode', false))
  );
end;
$function$;
