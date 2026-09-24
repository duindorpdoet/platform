-- Parents can maintain children until the organizer publishes the final group.
-- Private participant and payment tables remain closed; only owned registrations
-- can be changed through the authenticated commands below.

create function app_private.registration_children_editable(_registration_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select registration.status = 'submitted'
      and not exists (
        select 1
        from app_private.group_registrations assignment
        where assignment.registration_id = registration.id
          and assignment.superseded_at is null
          and assignment.published_at is not null
      )
    from app_private.registrations registration
    where registration.id = _registration_id
  ), false)
$$;

create function app_private.registration_child_unpaid(_registration_child_id uuid)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare
  registration_child app_private.registration_children;
  payment app_private.payment_requests;
  batch app_private.child_payment_batches;
begin
  select * into registration_child
  from app_private.registration_children
  where id = _registration_child_id;

  if registration_child.id is null or registration_child.participation_status <> 'active' then
    return false;
  end if;
  if registration_child.unit_price_cents = 0 then
    return true;
  end if;

  if registration_child.child_payment_batch_id is not null then
    select * into batch
    from app_private.child_payment_batches
    where id = registration_child.child_payment_batch_id;
    return batch.status = 'awaiting_payment'
      and app_private.child_payment_batch_payload(batch.id) ->> 'status' = 'awaiting_payment';
  end if;

  select * into payment
  from app_private.payment_requests
  where registration_id = registration_child.registration_id
  order by created_at desc
  limit 1;

  if payment.id is null or payment.child_payment_mode then
    return true;
  end if;

  return payment.status in ('awaiting_link', 'awaiting_payment')
    and not exists (
      select 1
      from app_private.payment_entries entry
      where entry.request_id = payment.id
        and entry.entry_type <> 'reported'
        and entry.amount_cents <> 0
    );
end;
$$;

create function app_private.reconcile_registration_payment(_registration_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  payment app_private.payment_requests;
  amount_due integer;
  collected integer;
  has_open_batch boolean;
begin
  select coalesce(sum(child.unit_price_cents), 0)::integer
  into amount_due
  from app_private.registration_children child
  where child.registration_id = _registration_id
    and child.participation_status = 'active';

  select * into payment
  from app_private.payment_requests
  where registration_id = _registration_id
  order by created_at desc
  limit 1
  for update;

  if payment.id is null then return; end if;

  select coalesce(sum(entry.amount_cents) filter (where entry.entry_type <> 'reported'), 0)::integer
  into collected
  from app_private.payment_entries entry
  where entry.request_id = payment.id;

  select exists (
    select 1
    from app_private.child_payment_members member
    join app_private.child_payment_batches batch on batch.id = member.batch_id
    join app_private.registration_children child on child.id = member.registration_child_id
    where member.payment_request_id = payment.id
      and batch.status in ('awaiting_payment', 'reported')
      and child.participation_status = 'active'
      and child.child_payment_batch_id = batch.id
  ) into has_open_batch;

  update app_private.payment_requests
  set amount_cents = amount_due,
      external_url = case when child_payment_mode then null else external_url end,
      payment_batch_id = case when child_payment_mode then null else payment_batch_id end,
      status = case
        when collected > amount_due then 'refund_due'::app_private.payment_status
        when amount_due = 0 then 'waived'::app_private.payment_status
        when collected = amount_due then 'confirmed'::app_private.payment_status
        when collected > 0 then 'partial'::app_private.payment_status
        when child_payment_mode and has_open_batch then 'awaiting_payment'::app_private.payment_status
        when child_payment_mode then 'awaiting_link'::app_private.payment_status
        when external_url is not null then 'awaiting_payment'::app_private.payment_status
        else 'awaiting_link'::app_private.payment_status
      end,
      updated_at = now(),
      version = version + 1
  where id = payment.id;
end;
$$;

create function api.registration_child_add(
  _registration_id uuid,
  _expected_registration_version integer,
  _first_name text,
  _age_at_event integer,
  _accessibility_note text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  registration app_private.registrations;
  event_record app_private.events;
  payment app_private.payment_requests;
  legacy_batch app_private.payment_link_batches;
  child_record app_private.children;
  registration_child app_private.registration_children;
  party_id uuid;
  party_children integer;
  event_children integer;
  active_before integer;
  amount_before integer;
  active_after integer;
  amount_after integer;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if nullif(trim(coalesce(_first_name, '')), '') is null
     or char_length(trim(_first_name)) > 80
     or _age_at_event not between 0 and 20
     or char_length(coalesce(_accessibility_note, '')) > 500 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  select candidate.* into registration
  from app_private.registrations candidate
  where candidate.id = _registration_id
    and app_private.is_household_member(candidate.household_id, actor);
  if registration.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  perform pg_advisory_xact_lock(hashtextextended('payment-batch:' || registration.event_id, 0));
  select * into event_record from app_private.events where id = registration.event_id for update;
  perform assignment.id
  from app_private.group_registrations assignment
  where assignment.registration_id = registration.id and assignment.superseded_at is null
  order by assignment.id
  for update;
  select * into registration from app_private.registrations where id = _registration_id for update;

  if registration.version is distinct from _expected_registration_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  if not app_private.registration_children_editable(registration.id) then
    raise exception 'CHILDREN_LOCKED' using errcode = '23514';
  end if;

  select membership.party_id into party_id
  from app_private.together_memberships membership
  where membership.registration_id = registration.id and membership.left_at is null
  limit 1;
  if party_id is null then
    select count(*)::integer into party_children
    from app_private.registration_children child
    where child.registration_id = registration.id and child.participation_status = 'active';
  else
    perform party.id from app_private.together_parties party where party.id = party_id for update;
    party_children := app_private.together_party_child_count(party_id);
  end if;

  if party_children + 1 > coalesce((event_record.settings ->> 'maxGroupSize')::integer, 20) then
    raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode = '23514';
  end if;
  select count(*)::integer into event_children
  from app_private.registration_children child
  where child.event_id = registration.event_id and child.participation_status = 'active';
  if event_children + 1 > coalesce((event_record.settings ->> 'maxChildren')::integer, 300) then
    raise exception 'EVENT_CAPACITY_REACHED' using errcode = '23514';
  end if;

  select count(*)::integer, coalesce(sum(child.unit_price_cents), 0)::integer
  into active_before, amount_before
  from app_private.registration_children child
  where child.registration_id = registration.id and child.participation_status = 'active';

  select * into payment
  from app_private.payment_requests
  where registration_id = registration.id
  order by created_at desc limit 1
  for update;

  if payment.id is not null and not payment.child_payment_mode then
    if payment.status in ('reported', 'partial', 'confirmed', 'refund_due')
       or exists (
         select 1 from app_private.payment_entries entry
         where entry.request_id = payment.id
           and entry.entry_type <> 'reported'
           and entry.amount_cents <> 0
       ) then
      raise exception 'LEGACY_PAYMENT_REQUIRES_ORGANIZER' using errcode = '23514';
    end if;

    if payment.payment_batch_id is not null then
      perform request.id
      from app_private.payment_requests request
      where request.payment_batch_id = payment.payment_batch_id
      order by request.id
      for update;
      select * into legacy_batch
      from app_private.payment_link_batches
      where id = payment.payment_batch_id
      for update;
      if legacy_batch.status <> 'awaiting_payment' then
        raise exception 'PAYMENT_REPORTED' using errcode = '23514';
      end if;
      update app_private.payment_requests
      set external_url = null, payment_batch_id = null,
          status = 'awaiting_link', version = version + 1
      where payment_batch_id = legacy_batch.id;
      update app_private.payment_link_batches
      set status = 'cancelled', version = version + 1, updated_at = now()
      where id = legacy_batch.id;
      insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
      values (registration.event_id, actor, 'payment.batch_cancelled_for_child_change',
        'payment_batch', legacy_batch.id, jsonb_build_object('registrationId', registration.id));
    elsif payment.external_url is not null then
      update app_private.payment_requests
      set external_url = null, status = 'awaiting_link', version = version + 1
      where id = payment.id;
    end if;
  end if;

  insert into app_private.children(household_id, first_name, age_at_event, accessibility_note)
  values (
    registration.household_id,
    trim(_first_name),
    _age_at_event::smallint,
    nullif(trim(coalesce(_accessibility_note, '')), '')
  ) returning * into child_record;

  insert into app_private.registration_children(event_id, registration_id, child_id, unit_price_cents)
  values (registration.event_id, registration.id, child_record.id, event_record.price_cents)
  returning * into registration_child;

  select count(*)::integer, coalesce(sum(child.unit_price_cents), 0)::integer
  into active_after, amount_after
  from app_private.registration_children child
  where child.registration_id = registration.id and child.participation_status = 'active';

  update app_private.registrations
  set price_snapshot_cents = amount_after, updated_at = now(), version = version + 1
  where id = registration.id
  returning * into registration;
  perform app_private.reconcile_registration_payment(registration.id);

  insert into app_private.registration_revisions(registration_id, version, changed_by, change_type, totals_before, totals_after)
  values (
    registration.id, registration.version, actor, 'parent_add_child',
    jsonb_build_object('childCount', active_before, 'amountCents', amount_before),
    jsonb_build_object('childCount', active_after, 'amountCents', amount_after)
  );
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (
    registration.event_id, actor, 'registration.child_added_by_parent',
    'registration_child', registration_child.id,
    jsonb_build_object('registrationId', registration.id, 'childCount', active_after, 'amountCents', amount_after)
  );

  return jsonb_build_object(
    'registrationId', registration.id,
    'registrationChildId', registration_child.id,
    'version', registration.version,
    'priceCents', amount_after
  );
end;
$$;


create function api.registration_child_remove(
  _registration_child_id uuid,
  _expected_registration_version integer,
  _expected_payment_version integer
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  registration app_private.registrations;
  registration_child app_private.registration_children;
  payment app_private.payment_requests;
  child_batch app_private.child_payment_batches;
  legacy_batch app_private.payment_link_batches;
  active_before integer;
  amount_before integer;
  active_after integer;
  amount_after integer;
  affected_registrations uuid[] := '{}'::uuid[];
  affected_registration_id uuid;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  select candidate.* into registration
  from app_private.registration_children child
  join app_private.registrations candidate on candidate.id = child.registration_id
  where child.id = _registration_child_id
    and app_private.is_household_member(candidate.household_id, actor);
  if registration.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  perform pg_advisory_xact_lock(hashtextextended('payment-batch:' || registration.event_id, 0));
  perform assignment.id
  from app_private.group_registrations assignment
  where assignment.registration_id = registration.id and assignment.superseded_at is null
  order by assignment.id
  for update;
  select * into registration
  from app_private.registrations
  where id = registration.id
  for update;
  select * into registration_child
  from app_private.registration_children
  where id = _registration_child_id
  for update;

  if registration.version is distinct from _expected_registration_version
     or registration_child.payment_version is distinct from _expected_payment_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  if not app_private.registration_children_editable(registration.id) then
    raise exception 'CHILDREN_LOCKED' using errcode = '23514';
  end if;
  if registration_child.participation_status <> 'active' then
    raise exception 'INVALID_TRANSITION' using errcode = '23514';
  end if;
  if not app_private.registration_child_unpaid(registration_child.id) then
    raise exception 'CHILD_ALREADY_PAID' using errcode = '23514';
  end if;

  select count(*)::integer, coalesce(sum(child.unit_price_cents), 0)::integer
  into active_before, amount_before
  from app_private.registration_children child
  where child.registration_id = registration.id and child.participation_status = 'active';

  select * into payment
  from app_private.payment_requests
  where registration_id = registration.id
  order by created_at desc limit 1
  for update;

  if registration_child.child_payment_batch_id is not null then
    perform request.id
    from app_private.child_payment_members member
    join app_private.payment_requests request on request.id = member.payment_request_id
    where member.batch_id = registration_child.child_payment_batch_id
    order by request.id
    for update;
    perform child.id
    from app_private.child_payment_members member
    join app_private.registration_children child on child.id = member.registration_child_id
    where member.batch_id = registration_child.child_payment_batch_id
    order by child.id
    for update;

    select * into child_batch
    from app_private.child_payment_batches
    where id = registration_child.child_payment_batch_id
    for update;
    if child_batch.status <> 'awaiting_payment'
       or app_private.child_payment_batch_payload(child_batch.id) ->> 'status' <> 'awaiting_payment' then
      raise exception 'CHILD_ALREADY_PAID' using errcode = '23514';
    end if;

    select coalesce(array_agg(distinct request.registration_id order by request.registration_id), '{}'::uuid[])
    into affected_registrations
    from app_private.child_payment_members member
    join app_private.payment_requests request on request.id = member.payment_request_id
    where member.batch_id = child_batch.id;

    update app_private.child_payment_batches
    set status = 'cancelled', version = version + 1
    where id = child_batch.id;
    update app_private.registration_children child
    set child_payment_batch_id = null, payment_version = payment_version + 1
    where child.id in (
      select member.registration_child_id
      from app_private.child_payment_members member
      where member.batch_id = child_batch.id
    );
    insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (
      registration.event_id, actor, 'payment.child_batch_cancelled_for_child_removal',
      'child_payment_batch', child_batch.id,
      jsonb_build_object('registrationId', registration.id, 'registrationChildId', registration_child.id)
    );
  elsif payment.id is not null and not payment.child_payment_mode and payment.payment_batch_id is not null then
    perform request.id
    from app_private.payment_requests request
    where request.payment_batch_id = payment.payment_batch_id
    order by request.id
    for update;
    select * into legacy_batch
    from app_private.payment_link_batches
    where id = payment.payment_batch_id
    for update;
    if legacy_batch.status <> 'awaiting_payment'
       or app_private.payment_batch_payload(legacy_batch.id) ->> 'status' <> 'awaiting_payment' then
      raise exception 'CHILD_ALREADY_PAID' using errcode = '23514';
    end if;

    select coalesce(array_agg(distinct request.registration_id order by request.registration_id), '{}'::uuid[])
    into affected_registrations
    from app_private.payment_requests request
    where request.payment_batch_id = legacy_batch.id;

    update app_private.payment_requests
    set external_url = null, payment_batch_id = null,
        status = 'awaiting_link', version = version + 1
    where payment_batch_id = legacy_batch.id;
    update app_private.payment_link_batches
    set status = 'cancelled', version = version + 1, updated_at = now()
    where id = legacy_batch.id;
    insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (
      registration.event_id, actor, 'payment.batch_cancelled_for_child_removal',
      'payment_batch', legacy_batch.id,
      jsonb_build_object('registrationId', registration.id, 'registrationChildId', registration_child.id)
    );
  elsif payment.id is not null and not payment.child_payment_mode and payment.external_url is not null then
    update app_private.payment_requests
    set external_url = null, status = 'awaiting_link', version = version + 1
    where id = payment.id;
  end if;

  update app_private.registration_children
  set participation_status = 'cancelled',
      child_payment_batch_id = null,
      payment_version = payment_version + 1
  where id = registration_child.id;
  update app_private.children
  set archived_at = now(), updated_at = now(), version = version + 1
  where id = registration_child.child_id;

  select count(*)::integer, coalesce(sum(child.unit_price_cents), 0)::integer
  into active_after, amount_after
  from app_private.registration_children child
  where child.registration_id = registration.id and child.participation_status = 'active';

  update app_private.registrations
  set price_snapshot_cents = amount_after, updated_at = now(), version = version + 1
  where id = registration.id
  returning * into registration;

  perform app_private.reconcile_registration_payment(registration.id);
  foreach affected_registration_id in array affected_registrations loop
    if affected_registration_id is distinct from registration.id then
      perform app_private.reconcile_registration_payment(affected_registration_id);
    end if;
  end loop;

  insert into app_private.registration_revisions(registration_id, version, changed_by, change_type, totals_before, totals_after)
  values (
    registration.id, registration.version, actor, 'parent_remove_child',
    jsonb_build_object('childCount', active_before, 'amountCents', amount_before),
    jsonb_build_object('childCount', active_after, 'amountCents', amount_after)
  );
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (
    registration.event_id, actor, 'registration.child_removed_by_parent',
    'registration_child', registration_child.id,
    jsonb_build_object('registrationId', registration.id, 'childCount', active_after, 'amountCents', amount_after)
  );

  return jsonb_build_object(
    'registrationId', registration.id,
    'registrationChildId', registration_child.id,
    'version', registration.version,
    'priceCents', amount_after
  );
end;
$$;


alter function api.registration_snapshot(text) set schema app_private;
alter function app_private.registration_snapshot(text) rename to registration_snapshot_before_parent_child_changes;
revoke all on function app_private.registration_snapshot_before_parent_child_changes(text) from public, anon, authenticated;

create function api.registration_snapshot(_event_slug text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  result jsonb;
  enriched_children jsonb;
  target_registration_id uuid;
  editable boolean;
  locked_reason text;
begin
  result := app_private.registration_snapshot_before_parent_child_changes(_event_slug);
  if result #>> '{registration,id}' is null then return result; end if;

  target_registration_id := (result #>> '{registration,id}')::uuid;
  editable := app_private.registration_children_editable(target_registration_id);

  if not editable then
    if exists (
      select 1
      from app_private.group_registrations assignment
      where assignment.registration_id = target_registration_id
        and assignment.superseded_at is null
        and assignment.published_at is not null
    ) then
      locked_reason := 'group_finalized';
    else
      locked_reason := 'registration_not_active';
    end if;
  end if;

  select coalesce(
    jsonb_agg(
      row.value || jsonb_build_object(
        'canRemove',
        editable and app_private.registration_child_unpaid((row.value ->> 'id')::uuid)
      )
      order by row.ordinality
    ),
    '[]'::jsonb
  )
  into enriched_children
  from jsonb_array_elements(result #> '{registration,children}') with ordinality row(value, ordinality);

  result := jsonb_set(result, '{registration,children}', enriched_children);
  result := jsonb_set(
    result,
    '{registration}',
    (result #> '{registration}') || jsonb_build_object(
      'childrenEditable', editable,
      'childrenLockedReason', locked_reason
    )
  );
  return result;
end;
$$;

revoke all on function app_private.registration_children_editable(uuid) from public, anon, authenticated;
revoke all on function app_private.registration_child_unpaid(uuid) from public, anon, authenticated;
revoke all on function app_private.reconcile_registration_payment(uuid) from public, anon, authenticated;
revoke all on function api.registration_child_add(uuid, integer, text, integer, text) from public, anon;
revoke all on function api.registration_child_remove(uuid, integer, integer) from public, anon;
revoke all on function api.registration_snapshot(text) from public, anon;

grant execute on function api.registration_child_add(uuid, integer, text, integer, text) to authenticated;
grant execute on function api.registration_child_remove(uuid, integer, integer) to authenticated;
grant execute on function api.registration_snapshot(text) to authenticated;

select pg_notify('pgrst', 'reload schema');
