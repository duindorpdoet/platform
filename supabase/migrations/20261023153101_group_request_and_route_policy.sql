-- Apply the same event policy to participant requests and the alternate admin reader.
CREATE OR REPLACE FUNCTION api.registration_together_request(_registration_id uuid, _together_code text, _idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare registration app_private.registrations; event_record app_private.events; source_id uuid; target_id uuid;
  code text:=upper(trim(_together_code)); request app_private.together_join_requests; preview jsonb;
  receipt app_private.command_receipts; request_hash text; result jsonb;
begin
  select * into registration from app_private.registrations where id=_registration_id;
  if registration.id is null or not app_private.is_household_member(registration.household_id) then
    raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if code is null or code !~ '^[A-HJ-NP-Z2-9]{4}$' then raise exception 'INVALID_TOGETHER_CODE' using errcode='22023'; end if;
  if char_length(coalesce(_idempotency_key,'')) not between 10 and 100 then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
  select * into event_record from app_private.events where id=registration.event_id for update;
  select * into registration from app_private.registrations where id=_registration_id for update;
  request_hash:=encode(extensions.digest(jsonb_build_array(registration.id,code)::text,'sha256'),'hex');
  select * into receipt from app_private.command_receipts where actor_id=auth.uid()
    and command_type='together.participantRequest' and idempotency_key=_idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='22023'; end if;
    return receipt.safe_result;
  end if;
  if registration.status<>'submitted' or event_record.phase not in('draft','registration_open','registration_closed','planning') then
    raise exception 'TOGETHER_LOCKED' using errcode='23514'; end if;
  select party_id into source_id from app_private.together_memberships where registration_id=registration.id and left_at is null;
  select m.party_id into target_id from app_private.registrations r join app_private.together_memberships m on m.registration_id=r.id and m.left_at is null
    where r.event_id=registration.event_id and r.together_code=code and r.status='submitted';
  if source_id is null or target_id is null or source_id=target_id then raise exception 'INVALID_TOGETHER_CODE' using errcode='22023'; end if;
  perform id from app_private.together_parties where id in(source_id,target_id) order by id for update;
  select * into request from app_private.together_join_requests where source_party_id=source_id and status='pending';
  if request.id is not null then
    if request.requested_by_registration_id<>registration.id or request.requested_code<>code then
      raise exception 'OPEN_TOGETHER_REQUEST' using errcode='23514'; end if;
  else
    preview:=app_private.together_merge_preview(event_record.id,source_id,target_id);
    -- Capacity above the configured limit remains an explicit organizer decision;
    -- locked/publication/group conflicts cannot be introduced through this new entrypoint.
    if jsonb_array_length((preview->'blockers') - 'over_capacity')>0 or (preview->>'projectedChildren')::integer>app_private.event_group_size_limit(event_record.id) then
      raise exception 'TOGETHER_REQUEST_BLOCKED' using errcode='23514'; end if;
    insert into app_private.together_join_requests(event_id,source_party_id,target_party_id,requested_by_registration_id,
      requested_code,child_count_at_request,group_limit_at_request)
    values(event_record.id,source_id,target_id,registration.id,code,(preview#>>'{source,childCount}')::integer,
      (preview->>'maxGroupSize')::integer) returning * into request;
    insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
      values(event_record.id,auth.uid(),'together.join_requested','registration',registration.id,
        jsonb_build_object('requestId',request.id,'requiresApproval',true));
  end if;
  result:=jsonb_build_object('id',request.id,'status',request.status,'version',request.version);
  insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
    values(auth.uid(),'together.participantRequest',_idempotency_key,request_hash,result,now()+interval '10 years');
  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION api.admin_route_configuration_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; event_id uuid; options jsonb; enriched jsonb;
begin
  result := app_private.admin_route_configuration_snapshot_before_codes(_event_slug);
  select id into event_id from app_private.events where slug = _event_slug;
  options := coalesce(app_private.exact_preference_options(event_id), '{}'::jsonb);
  result := jsonb_set(result, '{settings}', coalesce(result -> 'settings', '{}'::jsonb) || options, true);
  select coalesce(jsonb_agg(item || jsonb_build_object(
    'code', portal.system_code, 'systemCode', portal.system_code
  ) order by ordinal), '[]'::jsonb) into enriched
  from jsonb_array_elements(coalesce(result -> 'portals', '[]'::jsonb)) with ordinality entries(item, ordinal)
  left join app_private.portals portal on portal.id = (item ->> 'id')::uuid;
  result := jsonb_set(result, '{portals}', enriched, true);
  select coalesce(jsonb_agg(
    jsonb_set(item || jsonb_build_object(
      'code', walking_group.system_code, 'systemCode', walking_group.system_code, 'displayName', walking_group.display_name
    ), '{registrations}', coalesce((
      select jsonb_agg(registration_item || jsonb_build_object(
        'preferredStartAt', registration.preferred_start_at, 'desiredEndAt', registration.desired_end_at
      ) order by registration_ordinal)
      from jsonb_array_elements(coalesce(item -> 'registrations', '[]'::jsonb))
        with ordinality registration_entries(registration_item, registration_ordinal)
      left join app_private.registrations registration on registration.id = (registration_item ->> 'id')::uuid
    ), '[]'::jsonb), true) order by ordinal
  ), '[]'::jsonb) into enriched
  from jsonb_array_elements(coalesce(result -> 'groups', '[]'::jsonb)) with ordinality entries(item, ordinal)
  left join app_private.walking_groups walking_group on walking_group.id = (item ->> 'id')::uuid;
  result := jsonb_set(result, '{groups}', enriched, true);
  select coalesce(jsonb_agg(item || jsonb_build_object(
    'preferredStartAt', registration.preferred_start_at, 'desiredEndAt', registration.desired_end_at
  ) order by ordinal), '[]'::jsonb) into enriched
  from jsonb_array_elements(coalesce(result -> 'unassigned', '[]'::jsonb)) with ordinality entries(item, ordinal)
  left join app_private.registrations registration on registration.id = (item ->> 'id')::uuid;
  result:=jsonb_set(result,'{unassigned}',enriched,true);
  return jsonb_set(result,'{settings}',coalesce(result->'settings','{}'::jsonb)||jsonb_build_object(
    'maxGroupSize',app_private.event_group_size_limit(event_id),
    'targetGroupSize',coalesce((select (e.settings->>'targetGroupSize')::integer from app_private.events e where e.id=event_id),app_private.event_group_size_limit(event_id)),
    'eventSettingsVersion',(select settings_version from app_private.events e where e.id=event_id)),true);
end;
$function$
;
