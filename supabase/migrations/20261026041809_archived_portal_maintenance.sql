-- Full organization maintenance includes archives; legacy active-only snapshot stays compatible.
CREATE OR REPLACE FUNCTION api.admin_portal_records_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare event_record app_private.events; actor uuid:=auth.uid();
begin
  select * into event_record from app_private.events where slug=_event_slug;
  if actor is null or event_record.id is null or not (app_private.has_capability(event_record.id,'portals_manage',actor)
    or app_private.has_capability(event_record.id,'event_admin',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  return jsonb_build_object(
    'eventId',event_record.id,'realtimeTopic','admin-event:'||event_record.id,
    'portals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', portal.id, 'code', portal.system_code, 'systemCode', portal.system_code,
        'name', portal.name, 'world', world.name, 'worldSlug', world.slug,
        'color', coalesce(portal.color, '#d59658'), 'description', portal.description,
        'instructionStatus',(select case when i.accepted_at is null and i.expires_at<=now() then 'expired' else o.status::text end from app_private.email_outbox o left join app_private.portal_team_invites i on i.id=(o.payload->>'inviteId')::uuid where o.message_type='portal_manual_instructions' and o.payload->>'portalId'=portal.id::text order by o.created_at desc limit 1),
        'maintenanceDraft',(select d.payload from app_private.portal_maintenance_drafts d where d.portal_id=portal.id),
        'intensity',portal.intensity,'accessibilityNotes',portal.accessibility_notes,'internalNotes',portal.internal_notes,
        'street',location.street,'houseNumber',location.house_number,'addition',location.addition,
        'visitMinutes',portal_window.visit_minutes,'bufferMinutes',portal_window.buffer_minutes,'windowCount',portal_window.window_count,
        'walkingConnectionVerified',app_private.portal_has_verified_walking_connection(portal.id),
        'approvalStatus', portal.approval_status, 'lifecycleStatus', portal.lifecycle_status,
        'operationStatus', portal.operation_status, 'recordSource', portal.record_source,
        'contactName', coalesce(portal.contact_name, application.private_draft_data ->> 'contactName'),
        'phone', coalesce(portal.contact_phone, application.private_draft_data ->> 'phone'),
        'email', coalesce(portal.contact_email, applicant.email),
        'address', concat_ws(' ', location.street, location.house_number, location.addition),
        'postalCode', location.postal_code, 'city', location.city,
        'geocodedLatitude', location.geocoded_latitude,
        'geocodedLongitude', location.geocoded_longitude,
        'markerLatitude', location.marker_latitude, 'markerLongitude', location.marker_longitude,
        'latitude', coalesce(location.marker_latitude, location.geocoded_latitude, location.latitude),
        'longitude', coalesce(location.marker_longitude, location.geocoded_longitude, location.longitude),
        'locationSource', location.location_source, 'markerReason', location.marker_reason,
        'markerUpdatedAt', location.marker_updated_at,
        'plannedOpensAt', portal_window.opens_at, 'plannedClosesAt', portal_window.closes_at,
        'maxGroups', portal_window.max_concurrent_groups, 'maxChildren', portal_window.max_children_per_visit,
        'candidateStartPoint', exists(select 1 from app_private.start_points sp where sp.linked_portal_id=portal.id and sp.active),
        'isFinal', portal.id = settings.final_portal_id, 'version', portal.version
      ) order by portal.system_number)
      from app_private.portals portal
      join app_private.worlds world on world.id = portal.world_id
      left join app_private.portal_applications application on application.id = portal.application_id
      left join auth.users applicant on applicant.id = application.applicant_user_id
      left join app_private.portal_private_locations location on location.portal_id = portal.id
      left join lateral (select min(opens_at) opens_at, max(closes_at) closes_at,
        max(max_concurrent_groups) max_concurrent_groups, max(max_children_per_visit) max_children_per_visit,
        max(visit_minutes) visit_minutes,max(buffer_minutes) buffer_minutes,count(*)::integer window_count
        from app_private.portal_windows where portal_id = portal.id) portal_window on true
      left join app_private.event_route_settings settings on settings.event_id = portal.event_id
      where portal.event_id = event_record.id
    ), '[]'::jsonb)
  );
end;
$function$
;


revoke all on function api.admin_portal_records_snapshot(text) from public,anon;
grant execute on function api.admin_portal_records_snapshot(text) to authenticated;

-- Correct archive metadata without reviving access, routing, windows or invitations.
create function api.admin_archived_portal_save(_event_slug text,_portal_id uuid,_payload jsonb,_expected_version integer,_reason text,_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; p app_private.portals; receipt app_private.command_receipts; hashed text; result jsonb;
begin
 select id into eid from app_private.events where slug=_event_slug for no key update;
 if auth.uid() is null or eid is null or not (app_private.has_capability(eid,'portals_manage',auth.uid()) or app_private.has_capability(eid,'event_admin',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if length(coalesce(_key,'')) not between 16 and 200 or length(trim(coalesce(_reason,'')))<10 or jsonb_typeof(_payload) is distinct from 'object' then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from jsonb_object_keys(_payload) k where k not in ('name','description','contactName','contactPhone','contactEmail','accessibilityNotes','internalNotes')) then raise exception 'ARCHIVE_METADATA_ONLY'; end if;
 hashed:=md5(jsonb_build_array(_event_slug,_portal_id,_payload,_expected_version,_reason)::text);
 select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.archive.metadata' and idempotency_key=_key;
 if receipt.id is not null then if receipt.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return receipt.safe_result; end if;
 select * into p from app_private.portals where id=_portal_id and event_id=eid for update;
 if p.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p.lifecycle_status<>'archived' then raise exception 'ARCHIVED_PORTAL_REQUIRED'; end if;
 if p.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if length(trim(coalesce(_payload->>'name',p.name))) not between 2 and 120 then raise exception 'INVALID_NAME'; end if;
 if nullif(trim(_payload->>'contactEmail'),'') is not null and trim(_payload->>'contactEmail') !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then raise exception 'INVALID_EMAIL'; end if;
 if exists(select 1 from jsonb_each_text(_payload) kv where length(kv.value)>4000) then raise exception 'INVALID_INPUT'; end if;
 update app_private.portals set name=trim(coalesce(_payload->>'name',name)),description=coalesce(_payload->>'description',description),
 contact_name=case when _payload?'contactName' then nullif(trim(_payload->>'contactName'),'') else contact_name end,
 contact_phone=case when _payload?'contactPhone' then nullif(trim(_payload->>'contactPhone'),'') else contact_phone end,
 contact_email=case when _payload?'contactEmail' then lower(nullif(trim(_payload->>'contactEmail'),'')) else contact_email end,
 accessibility_notes=coalesce(_payload->>'accessibilityNotes',accessibility_notes),internal_notes=coalesce(_payload->>'internalNotes',internal_notes),version=version+1,updated_at=clock_timestamp()
 where id=p.id returning * into p;
 result:=jsonb_build_object('id',p.id,'version',p.version,'archived',true);
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(auth.uid(),'portal.archive.metadata',_key,hashed,result,now()+interval '7 days');
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(eid,auth.uid(),'portal.archive.metadata','portal',p.id,jsonb_build_object('reason',_reason,'fields',(select jsonb_agg(k) from jsonb_object_keys(_payload) k),'version',p.version));
 perform realtime.send(jsonb_build_object('resource','portal','id',p.id),'snapshot_changed','admin-event:'||eid,true);
 return result;
end $$;
revoke all on function api.admin_archived_portal_save(text,uuid,jsonb,integer,text,text) from public,anon;
grant execute on function api.admin_archived_portal_save(text,uuid,jsonb,integer,text,text) to authenticated;
