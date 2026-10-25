CREATE OR REPLACE FUNCTION api.admin_group_composition_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := auth.uid(); event_record app_private.events;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'event_admin', actor)
    or app_private.has_capability(event_record.id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  return jsonb_build_object(
    'eventId', event_record.id,
    'phase', event_record.phase,
    'editable', event_record.phase in ('draft', 'registration_open', 'registration_closed', 'planning'),
    'maxGroupSize', app_private.event_group_size_limit(event_record.id),
    'targetGroupSize',coalesce((event_record.settings->>'targetGroupSize')::integer,least(15,app_private.event_group_size_limit(event_record.id))),
    'inputHash',app_private.group_operations_hash(event_record.id),
    'realtimeTopic', 'admin-event:' || event_record.id::text,
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', walking_group.id,
        'systemCode', walking_group.system_code,
        'displayName', walking_group.display_name,
        'status', walking_group.status,
        'version', walking_group.version,
        'compositionConfirmed',walking_group.composition_confirmed_hash=app_private.start_group_composition_hash(walking_group.id),
        'compositionRevision',walking_group.composition_revision,
        'communication',coalesce((select jsonb_object_agg(mail.status,mail.n) from (select o.status,count(*) n from app_private.email_outbox o where o.payload->>'groupId'=walking_group.id::text and o.message_type in ('group_composition_confirmed','group_schedule_published','group_schedule_corrected') group by o.status) mail),'{}'),
        'confirmedAt',walking_group.composition_confirmed_at,
        'preferredStartAt',app_private.dominant_start_preference(array(select a.registration_id from app_private.group_registrations a where a.group_id=walking_group.id and a.superseded_at is null)),
        'start',app_private.published_start_projection(walking_group.id),
        'draftStart',(select jsonb_build_object('startsAt',slot.starts_at,'pointId',slot.start_point_id,'state',s.state) from app_private.group_schedule_revisions s join app_private.start_slots slot on slot.id=s.start_slot_id where s.id=walking_group.current_schedule_revision_id),
        'locked', (walking_group.composition_confirmed_hash=app_private.start_group_composition_hash(walking_group.id)) or walking_group.status in ('ready', 'live', 'completed', 'stopped') or exists (
          select 1 from app_private.group_registrations locked_assignment
          where locked_assignment.group_id = walking_group.id and locked_assignment.superseded_at is null
            and locked_assignment.published_at is not null
        ) or exists (
          select 1 from app_private.group_schedule_revisions schedule
          where schedule.group_id = walking_group.id and schedule.state = 'published'
        ),
        'childCount', (select count(*) from app_private.group_registrations assignment
          join app_private.registration_children child on child.registration_id = assignment.registration_id
            and child.participation_status = 'active'
          where assignment.group_id = walking_group.id and assignment.superseded_at is null),
        'registrations', coalesce((select jsonb_agg(jsonb_build_object(
          'id', registration.id,
          'reference', registration.reference,
          'householdLabel', household.label,
          'parentEmail', primary_contact.email,
          'childCount', (select count(*) from app_private.registration_children child
            where child.registration_id = registration.id and child.participation_status = 'active'),
          'children', coalesce((select jsonb_agg(jsonb_build_object(
              'name', child_record.first_name,
              'age', child_record.age_at_event
            ) order by child_record.first_name, registration_child.id)
            from app_private.registration_children registration_child
            join app_private.children child_record on child_record.id = registration_child.child_id
            where registration_child.registration_id = registration.id
              and registration_child.participation_status = 'active'), '[]'::jsonb),
          'partyId', membership.party_id,
          'clusterReference', party.cluster_reference,
          'preferredStartAt', registration.preferred_start_at,
          'desiredEndAt', registration.desired_end_at,
          'paymentEligible',exists(select 1 from app_private.payment_requests p where p.registration_id=registration.id and p.status in ('confirmed','waived')),
          'assignmentPublished', assignment.published_at is not null
        ) order by household.label, registration.reference)
          from app_private.group_registrations assignment
          join app_private.registrations registration on registration.id = assignment.registration_id
          join app_private.households household on household.id = registration.household_id
          left join auth.users primary_contact on primary_contact.id = household.primary_contact_user_id
          left join app_private.together_memberships membership
            on membership.registration_id = registration.id and membership.left_at is null
          left join app_private.together_parties party on party.id = membership.party_id
          where assignment.group_id = walking_group.id and assignment.superseded_at is null and registration.status='submitted'), '[]'::jsonb)
      ) order by walking_group.system_number)
      from app_private.walking_groups walking_group where walking_group.event_id = event_record.id and walking_group.retired_at is null
    ), '[]'::jsonb),
    'unassigned', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', registration.id,
        'reference', registration.reference,
        'householdLabel', household.label,
        'parentEmail', primary_contact.email,
        'childCount', (select count(*) from app_private.registration_children child
          where child.registration_id = registration.id and child.participation_status = 'active'),
        'children', coalesce((select jsonb_agg(jsonb_build_object(
            'name', child_record.first_name,
            'age', child_record.age_at_event
          ) order by child_record.first_name, registration_child.id)
          from app_private.registration_children registration_child
          join app_private.children child_record on child_record.id = registration_child.child_id
          where registration_child.registration_id = registration.id
            and registration_child.participation_status = 'active'), '[]'::jsonb),
        'partyId', membership.party_id,
          'clusterReference', party.cluster_reference,
        'preferredStartAt', registration.preferred_start_at,
        'desiredEndAt', registration.desired_end_at,
        'paymentEligible',exists(select 1 from app_private.payment_requests p where p.registration_id=registration.id and p.status in ('confirmed','waived')),
        'assignmentPublished', false
      ) order by household.label, registration.reference)
      from app_private.registrations registration
      join app_private.households household on household.id = registration.household_id
      left join auth.users primary_contact on primary_contact.id = household.primary_contact_user_id
      left join app_private.together_memberships membership
        on membership.registration_id = registration.id and membership.left_at is null
          left join app_private.together_parties party on party.id = membership.party_id
      where registration.event_id = event_record.id and registration.status = 'submitted'
        and not exists (select 1 from app_private.group_registrations assignment
          where assignment.registration_id = registration.id and assignment.superseded_at is null)
    ), '[]'::jsonb)
  );
end;
$function$
;


CREATE OR REPLACE FUNCTION api.admin_startregie_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare base jsonb; e app_private.events; groups jsonb; routes jsonb; reservations jsonb;
begin
  base:=app_private.admin_startregie_snapshot_before_ops(_event_slug); -- Existing scoped admin authorization.
  select * into e from app_private.events where slug=_event_slug;
  base:=jsonb_set(base,'{settings}',coalesce(base->'settings','{}'::jsonb)||jsonb_build_object(
    'maxGroupSize',app_private.event_group_size_limit(e.id),
    'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,least(15,app_private.event_group_size_limit(e.id))),
    'eventSettingsVersion',e.settings_version),true);
  base:=jsonb_set(base,'{startPoints}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'readiness',app_private.start_point_readiness(p.id),
    'confirmed',app_private.start_point_readiness(p.id)->'confirmed',
    'latitude',app_private.start_point_location(p.id)->'latitude','longitude',app_private.start_point_location(p.id)->'longitude',
    'locationSource',app_private.start_point_location(p.id)->'source',
    'verified',app_private.start_point_safe_connection(p.id),'walkingConnectionVerifiedAt',p.walking_connection_verified_at,
    'walkingDistanceMeters',round(app_private.location_distance_m(coalesce(p.marker_latitude,p.geocoded_latitude,p.latitude),
      coalesce(p.marker_longitude,p.geocoded_longitude,p.longitude),n.coordinate[1]::numeric,n.coordinate[0]::numeric)))
    order by p.active desc,p.name) from jsonb_array_elements(base->'startPoints') item
    join app_private.start_points p on p.id=(item->>'id')::uuid
    left join app_private.walking_nodes n on n.id=p.walking_node_id),'[]'::jsonb),true);
  base:=jsonb_set(base,'{portals}',coalesce((select jsonb_agg(item||jsonb_build_object(
    'location',app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude),
    'latitude',app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude)->'latitude',
    'longitude',app_private.routing_position(l.marker_latitude,l.marker_longitude,l.geocoded_latitude,l.geocoded_longitude,l.latitude,l.longitude)->'longitude',
    'walkingConnectionVerified',app_private.portal_has_verified_walking_connection((item->>'id')::uuid)))
    from jsonb_array_elements(base->'portals') item left join app_private.portal_private_locations l on l.portal_id=(item->>'id')::uuid),'[]'::jsonb),true);
  -- Replace only the obsolete marker test. Unassigned groups, capacity and
  -- publication checks remain independent and unchanged.
  base:=jsonb_set(base,'{warnings}',coalesce((select jsonb_agg(w) from jsonb_array_elements(base->'warnings') w
    where w->>'code' not in ('MISSING_MARKER','WALKING_ROUTE_MISSING')),'[]'::jsonb)||coalesce((select jsonb_agg(jsonb_build_object(
      'code','MISSING_MARKER','resourceId',p.id,'resourceType','start_point','action','kaart',
      'message',p.public_label||' — '||case r->>'confirmationReason'
        when 'START_POINT_POSITION_MISSING' then 'Geen opgeslagen positie — plaats een marker.'
        when 'START_POINT_POSITION_INVALID' then 'Ongeldige positie — controleer de coördinaten en sla opnieuw op.'
        when 'START_POINT_ADDRESS_MISSING' then 'Adres ontbreekt — vul het adres van deze startlocatie in.'
        when 'LINKED_PORTAL_NOT_AVAILABLE' then 'Gekoppelde poort niet beschikbaar — controleer deze poort.'
        when 'LINKED_START_PORTAL_POSITION_INVALID' then 'De gekoppelde eerste poort '||coalesce(r->>'linkedPortalName','')||' heeft geen geldig adres en positie — controleer deze poort.'
        else 'Controleer het opgeslagen adres en de marker van deze startlocatie.' end) order by p.name)
      from app_private.start_points p cross join lateral(select app_private.start_point_readiness(p.id) r) c
      where p.event_id=e.id and p.active and not (r->>'canConfirm')::boolean), '[]'::jsonb),true);
  base:=jsonb_set(base,'{stats,missingMarkers}',to_jsonb((select count(*) from app_private.start_points p
    where p.event_id=e.id and p.active and not (app_private.start_point_location(p.id)->>'valid')::boolean)),true);
  select coalesce(jsonb_agg(jsonb_build_object('groupId',g.id,'scheduleId',s.id,'revision',coalesce(s.revision,0),
      'state',case when s.state='draft' and app_private.is_start_confirmation_current(s.id) then 'confirmed' else coalesce(s.state::text,'unassigned') end,
      'startPointId',p.id,'startPointName',p.name,'startsAt',slot.starts_at,
      'confirmedAt',case when s.state='published' or app_private.is_start_confirmation_current(s.id) then s.confirmed_at end,'timePublishedAt',pub.published_at,
      'addressReleaseAt',slot.starts_at-interval '1 hour','publishedStartsAt',pub.starts_at,
      'publishedRevision',pub.revision,'publishedAddressReleaseAt',pub.starts_at-interval '1 hour',
      'addressReleased',statement_timestamp()>=pub.starts_at-interval '1 hour','routeRevision',app_private.start_ops_route_revision(e.id)) order by g.system_code),'[]'::jsonb)
    into groups from app_private.walking_groups g
    left join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    left join app_private.start_slots slot on slot.id=coalesce(s.start_slot_id,g.start_slot_id)
    left join app_private.start_points p on p.id=slot.start_point_id
    left join lateral(select * from app_private.current_start_publication(g.id)) pub on true
    where g.event_id=e.id and g.retired_at is null;
  select coalesce(jsonb_object_agg(g.id,app_private.start_ops_route_preview(g.id)),'{}'::jsonb) into routes
    from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id
    where g.event_id=e.id and g.retired_at is null and (s.confirmed_at is not null or s.state='published');
  select coalesce(jsonb_agg(jsonb_build_object('id',coalesce(r.schedule_id::text,'legacy:'||r.group_id),
    'groupId',r.group_id,'startId',r.start_slot_id,'childCount',r.child_count,
    'expectedFinaleArrivalAt',coalesce(r.finale_at,settings.finale_last_arrival_at),
    'partyIds',coalesce((select jsonb_agg(a.registration_id order by a.registration_id) from app_private.group_registrations a
      where a.group_id=r.group_id and a.superseded_at is null),'[]'::jsonb))),'[]'::jsonb)
    into reservations from app_private.start_schedule_reservations(e.id) r
    join app_private.event_route_settings settings on settings.event_id=e.id;
  base:=jsonb_set(base,'{groups}',coalesce((select jsonb_agg(item) from jsonb_array_elements(base->'groups') item join app_private.walking_groups g on g.id=(item->>'id')::uuid where g.retired_at is null),'[]'));
  return base||jsonb_build_object('ops',jsonb_build_object('now',statement_timestamp(),'clockMode','server',
    'routeRevision',app_private.start_ops_route_revision(e.id),'inputHash',app_private.start_planning_input_hash(e.id),'groups',groups,'routes',routes,'walkingNodes','[]'::jsonb,'existingSchedules',reservations));
end;
$function$
;


CREATE OR REPLACE FUNCTION app_private.start_schedule_reservations(_event_id uuid)
 RETURNS TABLE(group_id uuid, schedule_id uuid, start_slot_id uuid, start_point_id uuid, starts_at timestamp with time zone, child_count integer, finale_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with sizes as (
    select g.id,count(c.id)::integer children from app_private.walking_groups g
    left join app_private.group_registrations a on a.group_id=g.id and a.superseded_at is null
    left join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active'
    where g.event_id=_event_id and g.retired_at is null and g.status not in ('finished','completed','stopped','cancelled')
      and not exists(select 1 from app_private.group_runs r where r.group_id=g.id and r.status in ('stopped','completed')) group by g.id
  ), published as (
    select distinct on(p.group_id) p.* from app_private.group_start_publications p
    where p.event_id=_event_id and not exists(select 1 from app_private.group_start_withdrawals w where w.group_id=p.group_id and w.through_publication_order>=p.publication_order) order by p.group_id,p.publication_order desc
  )
  select g.id,s.id,slot.id,slot.start_point_id,slot.starts_at,z.children,s.expected_finale_arrival_at
  from app_private.walking_groups g join sizes z on z.id=g.id
  join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id and s.state='draft'
  join app_private.start_slots slot on slot.id=s.start_slot_id and slot.active
  where g.event_id=_event_id and app_private.start_point_safe_connection(slot.start_point_id)
  union
  select p.group_id,p.schedule_id,(p.slot_snapshot->>'id')::uuid,(p.slot_snapshot->>'start_point_id')::uuid,
    p.starts_at,z.children,s.expected_finale_arrival_at
  from published p join sizes z on z.id=p.group_id
  left join app_private.group_schedule_revisions s on s.id=p.schedule_id
$function$
;


create or replace function app_private.protect_confirmed_composition()
returns trigger language plpgsql security definer set search_path='' as $$
declare gid uuid:=case when tg_op='DELETE' then old.group_id else new.group_id end; protected boolean;
begin
 if tg_op='UPDATE' and new.group_id=old.group_id and new.registration_id=old.registration_id and new.superseded_at is not distinct from old.superseded_at then return new;end if;
 select g.composition_confirmed_hash is not null into protected from app_private.walking_groups g where g.id=gid;
 if protected then raise exception 'COMPOSITION_REOPEN_REQUIRED' using errcode='23514';end if;
 if tg_op='DELETE' then return old;else return new;end if;
end $$;
drop trigger if exists protect_confirmed_composition on app_private.group_registrations;
create trigger protect_confirmed_composition before insert or update or delete on app_private.group_registrations for each row execute function app_private.protect_confirmed_composition();
revoke all on function app_private.protect_confirmed_composition() from public,anon,authenticated;
create or replace function api.admin_startregie_confirm_and_send(_event_slug text,_expected_revisions jsonb,_expected_settings_version integer,_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; receipt app_private.command_receipts; fingerprint text; result jsonb; item jsonb; g uuid; ids uuid[]:='{}';
begin
 select * into e from app_private.events where slug=_event_slug for update;
 if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;

 if length(coalesce(_idempotency_key,'')) not between 16 and 200 or jsonb_typeof(_expected_revisions) is distinct from 'array' or jsonb_array_length(_expected_revisions) not between 1 and 500 then raise exception 'VALIDATION_ERROR' using errcode='22023';end if;
 fingerprint:=encode(extensions.digest(jsonb_build_object('event',e.id,'revisions',_expected_revisions,'settings',_expected_settings_version)::text,'sha256'),'hex');
 select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='starts.confirm_and_send' and idempotency_key=_idempotency_key;
 if receipt.id is not null then
  if receipt.request_hash<>fingerprint then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505';end if;return receipt.safe_result;
 end if;
 if e.settings_version is distinct from _expected_settings_version then raise exception 'STALE_VERSION' using errcode='40001';end if;
 for item in select * from jsonb_array_elements(_expected_revisions) loop
  select s.group_id into g from app_private.group_schedule_revisions s join app_private.walking_groups wg on wg.id=s.group_id and wg.event_id=e.id and wg.retired_at is null where s.id=(item->>'id')::uuid and s.id=wg.current_schedule_revision_id and s.revision=(item->>'revision')::integer;
  if g is null then raise exception 'STALE_REVISION' using errcode='40001';end if;
  if not exists(select 1 from app_private.group_schedule_revisions s where s.id=(item->>'id')::uuid and s.state='published') then
   perform api.admin_startregie_confirm_start(_event_slug,g,(item->>'revision')::integer,_expected_settings_version);
   ids:=array_append(ids,(item->>'id')::uuid);
  end if;
 end loop;
 if cardinality(ids)>0 then result:=app_private.publish_startregie_ops(_event_slug,ids,'Startafspraken expliciet bevestigd en verstuurd');else result:=jsonb_build_object('published',0);end if;
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(auth.uid(),'starts.confirm_and_send',_idempotency_key,fingerprint,result,now()+interval '7 days');
 return result;
end $$;
revoke all on function api.admin_startregie_confirm_and_send(text,jsonb,integer,text) from public,anon;
grant execute on function api.admin_startregie_confirm_and_send(text,jsonb,integer,text) to authenticated;

CREATE OR REPLACE FUNCTION api.admin_dashboard(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  eid uuid;
  base jsonb;
begin
  select
    id
  into
    eid
  from
    app_private.events
  where
    slug = _event_slug;
  if exists (
    select
      1
    from
      app_private.event_capabilities c
    where
      c.event_id = eid
      and c.user_id = auth.uid ()
      and c.revoked_at is null
      and c.capability in ('event_admin', 'registration_manage', 'portals_manage', 'groups_manage', 'live_support')) then
    base:=app_private.admin_dashboard_before_editorial (_event_slug);
    return jsonb_set(base,'{event}',coalesce(base->'event','{}')||(
      select jsonb_build_object('maxGroupSize',app_private.event_group_size_limit(e.id),
       'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,least(15,app_private.event_group_size_limit(e.id))),
       'targetFollowsMaximum',not(e.settings?'targetGroupSize'),'settingsVersion',e.settings_version)
      from app_private.events e where e.id=eid));
  end if;
  if not exists (
    select
      1
    from
      app_private.event_capabilities c
    where
      c.event_id = eid
      and c.user_id = auth.uid ()
      and c.revoked_at is null
      and c.capability in ('content_manage', 'content_publish', 'communications_manage', 'communications_send')) then
    raise exception 'NOT_AUTHORIZED'
      using errcode = '42501';
  end if;
  return jsonb_build_object('event', (
      select
        jsonb_build_object('id', e.id, 'title', e.title, 'phase', e.phase, 'date', e.local_date, 'settingsVersion', e.settings_version, 'maxGroupSize', app_private.event_group_size_limit(e.id), 'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,least(15,app_private.event_group_size_limit(e.id))), 'targetFollowsMaximum',not(e.settings?'targetGroupSize'))
    from app_private.events e
    where
      e.id = eid), 'counts', '{}'::jsonb, 'imports', '[]'::jsonb, 'recentActivity', '[]'::jsonb);
end
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
    'targetGroupSize',coalesce((select (e.settings->>'targetGroupSize')::integer from app_private.events e where e.id=event_id),least(15,app_private.event_group_size_limit(event_id))),
    'eventSettingsVersion',(select settings_version from app_private.events e where e.id=event_id)),true);
end;
$function$
;

CREATE OR REPLACE FUNCTION api.admin_group_size_policy_save(_event_slug text, _max_group_size integer, _target_group_size integer, _expected_settings_version integer, _expected_impact_hash text, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  'targetGroupSize',coalesce(_target_group_size,least(15,_max_group_size)),'followsMaximum',_target_group_size is null,
  'groups',impact->'groups','parties',impact->'parties');
end $function$
;

CREATE OR REPLACE FUNCTION app_private.admin_startregie_snapshot_before_ops(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  base jsonb;
  warning_rows jsonb;
  capacity_conflicts integer;
begin
  select * into event_record from app_private.events where slug = _event_slug;
  if actor is null or event_record.id is null or not (
    app_private.has_capability(event_record.id, 'groups_manage', actor)
    or app_private.has_capability(event_record.id, 'event_admin', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  base := api.admin_route_configuration_snapshot(_event_slug);

  select count(*)::integer into capacity_conflicts
  from (
    select slot.start_point_id, slot.starts_at
    from app_private.walking_groups walking_group
    join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
    join app_private.start_slots slot on slot.id = schedule.start_slot_id
    join app_private.start_points point on point.id = slot.start_point_id
    where walking_group.retired_at is null and walking_group.event_id = event_record.id and schedule.state in ('draft', 'published')
    group by slot.start_point_id, slot.starts_at, point.max_gathering_groups, point.max_gathering_children
    having count(*) > point.max_gathering_groups
      or sum((select count(*) from app_private.group_registrations assignment
        join app_private.registration_children child on child.registration_id = assignment.registration_id
          and child.participation_status = 'active'
        where assignment.group_id = schedule.group_id and assignment.superseded_at is null)) > point.max_gathering_children
  ) conflicts;

  select coalesce(jsonb_agg(item order by priority, label), '[]'::jsonb) into warning_rows
  from (
    select 1 priority, 'UNASSIGNED_GROUPS' code,
      count(*)::text || ' routegroep(en) hebben nog geen startpunt.' label,
      'indeling' action, null::uuid resource_id
    from app_private.walking_groups walking_group
    where walking_group.retired_at is null and walking_group.event_id = event_record.id and walking_group.current_schedule_revision_id is null
    having count(*) > 0
    union all
    select 2, 'MISSING_MARKER', 'De marker van ' || point.name || ' is nog niet routeklaar.',
      'kaart', point.id
    from app_private.start_points point
    where point.event_id = event_record.id and point.active
      and (coalesce(point.marker_latitude, point.geocoded_latitude, point.latitude) is null or point.walking_node_id is null)
    union all
    select 3, 'MARKER_DISTANCE', 'De routingmarker van ' || point.name || ' ligt '
      || round(app_private.location_distance_m(point.geocoded_latitude, point.geocoded_longitude,
        point.marker_latitude, point.marker_longitude))::integer || ' meter van het officiële adres.',
      'kaart', point.id
    from app_private.start_points point
    where point.event_id = event_record.id and point.active and point.location_source = 'manual'
      and app_private.location_distance_m(point.geocoded_latitude, point.geocoded_longitude,
        point.marker_latitude, point.marker_longitude) > 100
    union all
    select 4, 'PORTAL_UNAVAILABLE', portal.system_code || ' is niet beschikbaar bij de geplande start van ' || walking_group.system_code || '.',
      'indeling', walking_group.id
    from app_private.walking_groups walking_group
    join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
    join app_private.start_slots slot on slot.id = schedule.start_slot_id
    join app_private.start_points point on point.id = slot.start_point_id and point.linked_portal_id is not null
    join app_private.portals portal on portal.id = point.linked_portal_id
    where walking_group.retired_at is null and walking_group.event_id = event_record.id and not exists (
      select 1 from app_private.portal_windows portal_window
      where portal_window.portal_id = portal.id and slot.starts_at between portal_window.opens_at and portal_window.closes_at
    )
    union all
    select 5, 'CAPACITY', capacity_conflicts::text || ' startmoment(en) overschrijden de ingestelde capaciteit.',
      'indeling', null::uuid
    where capacity_conflicts > 0
  ) warnings(priority, code, label, action, resource_id)
  cross join lateral (select jsonb_build_object(
    'code', warnings.code, 'message', warnings.label, 'action', warnings.action, 'resourceId', warnings.resource_id
  ) item) built;

  return jsonb_build_object(
    'eventId', event_record.id,
    'realtimeTopic', 'admin-event:' || event_record.id::text,
    'settings', coalesce(base -> 'settings', '{}'::jsonb) || coalesce((
      select jsonb_build_object(
        'startIntervalMinutes', settings.start_interval_minutes,
        'preferenceGreenMinutes', settings.preference_green_minutes,
        'preferenceAmberMinutes', settings.preference_amber_minutes
      ) from app_private.event_route_settings settings where settings.event_id = event_record.id
    ), '{}'::jsonb),
    'startPoints', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', point.id, 'name', point.name, 'publicLabel', point.public_label,
        'pointType', point.point_type, 'linkedPortalId', point.linked_portal_id,
        'privateAddress', point.private_address,
        'publicArrivalInstructions', point.public_arrival_instructions,
        'internalNotes', point.internal_notes, 'availableFrom', point.available_from,
        'availableUntil', point.available_until, 'safeApproach', point.safe_approach,
        'countsAsFirstPortalVisit', point.counts_as_first_portal_visit,
        'contactName', point.contact_name, 'contactPhone', point.contact_phone,
        'geocodedLatitude', point.geocoded_latitude, 'geocodedLongitude', point.geocoded_longitude,
        'markerLatitude', point.marker_latitude, 'markerLongitude', point.marker_longitude,
        'latitude', coalesce(point.marker_latitude, point.geocoded_latitude, point.latitude),
        'longitude', coalesce(point.marker_longitude, point.geocoded_longitude, point.longitude),
        'locationSource', point.location_source, 'markerReason', point.marker_reason,
        'markerUpdatedAt', point.marker_updated_at, 'walkingNodeId', point.walking_node_id,
        'walkingNodeUpdatedAt', point.walking_node_updated_at,
        'verified', point.verified_at is not null and point.walking_node_id is not null,
        'accessible', point.accessible, 'accessibilityNotes', point.accessibility_notes,
        'maxGroups', point.max_gathering_groups, 'maxChildren', point.max_gathering_children,
        'active', point.active, 'version', point.version,
        'markerDistanceMeters', round(app_private.location_distance_m(
          point.geocoded_latitude, point.geocoded_longitude, point.marker_latitude, point.marker_longitude
        )),
        'slots', coalesce((select jsonb_agg(jsonb_build_object(
          'id', slot.id, 'startsAt', slot.starts_at, 'maxGroups', slot.max_groups,
          'maxChildren', slot.max_children, 'active', slot.active
        ) order by slot.starts_at) from app_private.start_slots slot where slot.start_point_id = point.id), '[]'::jsonb)
      ) order by point.active desc, point.name)
      from app_private.start_points point where point.event_id = event_record.id
    ), '[]'::jsonb),
    'portals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', portal.id, 'code', portal.system_code, 'systemCode', portal.system_code,
        'name', portal.name, 'world', world.name, 'worldSlug', world.slug,
        'color', coalesce(portal.color, '#d59658'), 'description', portal.description,
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
        'candidateStartPoint', portal.candidate_start_point,
        'isFinal', portal.id = settings.final_portal_id, 'version', portal.version
      ) order by portal.system_number)
      from app_private.portals portal
      join app_private.worlds world on world.id = portal.world_id
      left join app_private.portal_applications application on application.id = portal.application_id
      left join auth.users applicant on applicant.id = application.applicant_user_id
      left join app_private.portal_private_locations location on location.portal_id = portal.id
      left join lateral (select min(opens_at) opens_at, max(closes_at) closes_at,
        max(max_concurrent_groups) max_concurrent_groups, max(max_children_per_visit) max_children_per_visit
        from app_private.portal_windows where portal_id = portal.id) portal_window on true
      left join app_private.event_route_settings settings on settings.event_id = portal.event_id
      where portal.event_id = event_record.id and portal.lifecycle_status <> 'archived'
    ), '[]'::jsonb),
    'groups', coalesce(base -> 'groups', '[]'::jsonb),
    'unassigned', coalesce(base -> 'unassigned', '[]'::jsonb),
    'finaleFlow', coalesce(base -> 'finaleFlow', '[]'::jsonb),
    'warnings', warning_rows,
    'stats', jsonb_build_object(
      'activeStartPoints', (select count(*) from app_private.start_points where event_id = event_record.id and active),
      'plannedGroups', (select count(*) from app_private.walking_groups where retired_at is null and event_id = event_record.id and current_schedule_revision_id is not null),
      'unassignedGroups', (select count(*) from app_private.walking_groups where retired_at is null and event_id = event_record.id and current_schedule_revision_id is null),
      'withinPreferencePercent', coalesce((select round(100.0 * count(*) filter (where schedule.preference_match in ('good', 'neutral')) / nullif(count(*), 0))
        from app_private.walking_groups walking_group join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
        where walking_group.retired_at is null and walking_group.event_id = event_record.id), 0),
      'capacityConflicts', capacity_conflicts,
      'missingMarkers', (select count(*) from app_private.start_points point where point.event_id = event_record.id and point.active
        and (coalesce(point.marker_latitude, point.geocoded_latitude, point.latitude) is null or point.walking_node_id is null)),
      'unavailableLinkedPortals', (select count(distinct point.linked_portal_id)
        from app_private.walking_groups walking_group
        join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
        join app_private.start_slots slot on slot.id = schedule.start_slot_id
        join app_private.start_points point on point.id = slot.start_point_id and point.linked_portal_id is not null
        where walking_group.retired_at is null and walking_group.event_id = event_record.id and not exists (
          select 1 from app_private.portal_windows portal_window where portal_window.portal_id = point.linked_portal_id
            and slot.starts_at between portal_window.opens_at and portal_window.closes_at)),
      'publicationStatus', coalesce((select 'Gepubliceerd · versie ' || version::text from app_private.start_planning_versions
        where event_id = event_record.id and state = 'published'), 'Nog niet gepubliceerd')
    ),
    'planningVersions', coalesce((select jsonb_agg(jsonb_build_object(
      'id', version.id, 'version', version.version, 'state', version.state,
      'publishedAt', version.published_at, 'reason', version.reason
    ) order by version.version desc) from app_private.start_planning_versions version
      where version.event_id = event_record.id), '[]'::jsonb)
  );
end;
$function$
;

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
          where owned_portal.event_id = event_record.id and candidate.user_id = actor and candidate.revoked_at is null
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
$function$
;

CREATE OR REPLACE FUNCTION api.admin_live_snapshot(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := auth.uid(); v_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'live_support', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'groupId', walking_group.id,
    'groupCode', walking_group.code,
    'groupVersion', walking_group.version,
    'leaderEmail', (
      select lower(users.email)
      from app_private.group_leaders leader
      join auth.users users on users.id = leader.user_id
      where leader.group_id = walking_group.id and leader.active_until is null
      order by leader.revision desc limit 1
    ),
    'runId', run.id,
    'runStatus', run.status,
    'runVersion', run.version,
    'stopId', run.current_stop_id,
    'portalName', (
      select portal.name
      from app_private.run_stops stop
      join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
      join app_private.portals portal on portal.id = plan_stop.portal_id
      where stop.id = run.current_stop_id
    )
  ) order by walking_group.code)
  from app_private.walking_groups walking_group
  join app_private.group_runs run on run.group_id = walking_group.id and run.status in ('live', 'paused')
  where walking_group.retired_at is null and walking_group.event_id = v_event_id), '[]'::jsonb);
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.admin_dashboard_before_group_capacity(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not (
    app_private.has_capability(v_event_id, 'event_admin', actor)
    or app_private.has_capability(v_event_id, 'registration_manage', actor)
    or app_private.has_capability(v_event_id, 'portals_manage', actor)
    or app_private.has_capability(v_event_id, 'groups_manage', actor)
    or app_private.has_capability(v_event_id, 'live_support', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return jsonb_build_object(
    'event', (select jsonb_build_object(
      'id', id,
      'title', title,
      'phase', phase,
      'date', local_date,
      'settingsVersion', settings_version,
      'groupRegistrationOpen', coalesce((settings ->> 'groupRegistrationOpen')::boolean, false),
      'portalRegistrationOpen', coalesce((settings ->> 'portalRegistrationOpen')::boolean, true)
    ) from app_private.events where id = v_event_id),
    'counts', jsonb_build_object(
      'registrations', (select count(*) from app_private.registrations where event_id = v_event_id and status = 'submitted'),
      'children', (select count(*) from app_private.registration_children where event_id = v_event_id and participation_status = 'active'),
      'portalApplications', (select count(*) from app_private.portal_applications where event_id = v_event_id and review_status = 'submitted'),
      'approvedPortals', (select count(*) from app_private.portals where event_id = v_event_id and approval_status = 'approved'),
      'groups', (select count(*) from app_private.walking_groups where retired_at is null and event_id = v_event_id),
      'liveGroups', (select count(*) from app_private.walking_groups where retired_at is null and event_id = v_event_id and status = 'live'),
      'openSupportCases', (select count(*) from app_private.support_cases where event_id = v_event_id and status in ('open', 'acknowledged')),
      'unconfirmedPayments', (select count(*) from app_private.payment_requests payment join app_private.registrations registration on registration.id = payment.registration_id where registration.event_id = v_event_id and payment.status not in ('confirmed', 'waived', 'refunded'))
    ),
    'imports', coalesce((select jsonb_agg(jsonb_build_object('id', batch.id, 'kind', batch.kind, 'dryRun', batch.dry_run, 'status', batch.status, 'createdAt', batch.created_at) order by batch.created_at desc) from (select * from app_private.import_batches where event_id = v_event_id order by created_at desc limit 10) batch), '[]'::jsonb),
    'recentActivity', coalesce((select jsonb_agg(jsonb_build_object('action', audit.action, 'resourceType', audit.resource_type, 'createdAt', audit.created_at) order by audit.created_at desc) from (select * from app_private.audit_events where event_id = v_event_id order by created_at desc limit 20) audit), '[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.admin_planning_snapshot_before_group_capacity(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not app_private.has_capability(v_event_id, 'groups_manage', actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return jsonb_build_object(
    'parties', coalesce((select jsonb_agg(jsonb_build_object(
      'id', registration.id,
      'childCount', (select count(*) from app_private.registration_children child where child.registration_id = registration.id and child.participation_status = 'active'),
      'requestedStartId', registration.start_preference_id,
      'togetherKey', membership.party_id
    ) order by registration.id)
    from app_private.registrations registration
    left join app_private.together_memberships membership on membership.registration_id = registration.id and membership.left_at is null
    where registration.event_id = v_event_id and registration.status = 'submitted'
      and not exists (select 1 from app_private.group_registrations assignment where assignment.registration_id = registration.id and assignment.superseded_at is null)), '[]'::jsonb),
    'starts', coalesce((select jsonb_agg(jsonb_build_object('id', slot.id, 'startsAt', slot.starts_at, 'maxGroups', slot.max_groups, 'maxChildren', slot.max_children) order by slot.starts_at, slot.id) from app_private.start_slots slot where slot.event_id = v_event_id and slot.active and slot.location_verified_at is not null), '[]'::jsonb),
    'portals', coalesce((select jsonb_agg(jsonb_build_object(
      'id', portal.id, 'worldId', portal.world_id, 'opensAt', portal_window.opens_at, 'closesAt', portal_window.closes_at,
      'visitMinutes', portal_window.visit_minutes, 'maxConcurrentGroups', portal_window.max_concurrent_groups,
      'maxChildren', portal_window.max_children_per_visit, 'maxTotalChildren', portal_window.max_children_total
    ) order by portal.id)
    from app_private.portals portal
    join lateral (select * from app_private.portal_windows candidate where candidate.portal_id = portal.id order by candidate.opens_at limit 1) portal_window on true
    join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
    where portal.event_id = v_event_id and portal.approval_status = 'approved'), '[]'::jsonb),
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', walking_group.id,
        'code', walking_group.code,
        'status', walking_group.status,
        'planId', plan.id,
        'revision', plan.revision,
        'planState', plan.state,
        'portalIds', coalesce((
          select jsonb_agg(stop.portal_id order by stop.position)
          from app_private.route_plan_stops stop where stop.plan_version_id = plan.id
        ), '[]'::jsonb)
      ) order by walking_group.code)
      from app_private.walking_groups walking_group
      join app_private.route_plan_versions plan on plan.id = walking_group.current_plan_version_id
      where walking_group.retired_at is null and walking_group.event_id = v_event_id
    ), '[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.admin_evening_cockpit_before_codes(_event_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not (
    app_private.has_capability(v_event_id, 'live_support', actor)
    or app_private.has_capability(v_event_id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return jsonb_build_object(
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'groupId', walking_group.id, 'groupCode', walking_group.code, 'groupVersion', walking_group.version,
        'status', walking_group.status, 'runId', run.id, 'runStatus', run.status, 'runVersion', run.version,
        'currentStopId', run.current_stop_id, 'currentPortal', portal.name,
        'currentKind', stop.stop_kind, 'lastConfirmedAt', run.updated_at,
        'currentCoordinate', case when location.latitude is null then null else jsonb_build_array(location.longitude, location.latitude) end,
        'leaderEmail', (select users.email from app_private.group_leaders leader
          join auth.users users on users.id = leader.user_id
          where leader.group_id = walking_group.id and leader.active_from <= now()
            and (leader.active_until is null or leader.active_until > now())
          order by leader.active_from desc limit 1),
        'responsibleAdults', coalesce((select jsonb_agg(distinct jsonb_build_object('userId', users.id, 'email', users.email))
          from app_private.group_registrations assignment
          join app_private.registrations registration on registration.id = assignment.registration_id
          join app_private.household_members member on member.household_id = registration.household_id and member.revoked_at is null
          join auth.users users on users.id = member.user_id
          where assignment.group_id = walking_group.id and assignment.superseded_at is null), '[]'::jsonb),
        'elapsedSeconds', case when run.started_at is null then null else greatest(0, extract(epoch from (now() - run.started_at))::integer) end,
        'effectiveStopAt', schedule.effective_ordinary_stop_at,
        'expectedFinaleArrivalAt', coalesce(finale_reservation.reserved_from, schedule.expected_finale_arrival_at),
        'childCount', (select count(*) from app_private.group_registrations assignment
          join app_private.registration_children child on child.registration_id = assignment.registration_id and child.participation_status = 'active'
          where assignment.group_id = walking_group.id and assignment.superseded_at is null)
      ) order by walking_group.code)
      from app_private.walking_groups walking_group
      left join app_private.group_runs run on run.group_id = walking_group.id and run.status in ('ready', 'live', 'paused')
      left join app_private.run_stops stop on stop.id = run.current_stop_id
      left join app_private.route_plan_stops plan_stop on plan_stop.id = stop.plan_stop_id
      left join app_private.portals portal on portal.id = coalesce(stop.portal_id, plan_stop.portal_id)
      left join app_private.portal_private_locations location on location.portal_id = portal.id
      left join app_private.group_schedule_revisions schedule on schedule.id = walking_group.current_schedule_revision_id
      left join app_private.portal_reservations finale_reservation on finale_reservation.run_id = run.id
        and finale_reservation.kind = 'finale' and finale_reservation.status in ('held', 'active')
      where walking_group.retired_at is null and walking_group.event_id = v_event_id
    ), '[]'::jsonb),
    'portals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', portal.id, 'name', portal.name, 'operationStatus', portal.operation_status, 'version', portal.version,
        'isFinal', portal.id = settings.final_portal_id,
        'activeReservations', (select count(*) from app_private.portal_reservations reservation
          where reservation.portal_id = portal.id and reservation.status in ('held', 'active')),
        'expectedChildren', (select coalesce(sum(reservation.child_count), 0) from app_private.portal_reservations reservation
          where reservation.portal_id = portal.id and reservation.status in ('held', 'active'))
      ) order by portal.id = settings.final_portal_id desc, portal.name)
      from app_private.portals portal
      join app_private.event_route_settings settings on settings.event_id = portal.event_id
      where portal.event_id = v_event_id and portal.approval_status = 'approved'
    ), '[]'::jsonb),
    'alerts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', alert.id, 'priority', alert.priority, 'code', alert.code,
        'message', alert.message, 'groupId', alert.group_id, 'portalId', alert.portal_id,
        'createdAt', alert.created_at
      ) order by case alert.priority when 'urgent' then 0 when 'warning' then 1 else 2 end, alert.created_at)
      from app_private.route_alerts alert where alert.event_id = v_event_id and alert.status = 'open'
    ), '[]'::jsonb)
  );
end;
$function$
;
