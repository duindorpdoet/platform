alter table app_private.support_cases
  add column registration_id uuid references app_private.registrations(id) on delete restrict,
  add column request_payload jsonb not null default '{}'::jsonb
    check (jsonb_typeof(request_payload) = 'object');

create index support_cases_registration_status_idx
  on app_private.support_cases(registration_id, status)
  where registration_id is not null;

create or replace function api.registration_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event app_private.events;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into v_event from app_private.events where slug = _event_slug;
  if v_event.id is null then return null; end if;
  return (
    select jsonb_build_object(
      'event', jsonb_build_object(
        'changeDeadline', v_event.change_deadline,
        'changesOpen', v_event.change_deadline is null or v_event.change_deadline > now()
      ),
      'household', jsonb_build_object('id', household.id, 'label', household.label, 'phone', household.phone, 'version', household.version),
      'draft', case when draft.id is null then null else jsonb_build_object('payload', draft.payload, 'version', draft.version, 'updatedAt', draft.updated_at) end,
      'registration', case when registration.id is null then null else jsonb_build_object(
        'id', registration.id,
        'reference', registration.reference,
        'status', registration.status,
        'priceCents', registration.price_snapshot_cents,
        'version', registration.version,
        'children', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', registration_child.id,
            'firstName', child.first_name,
            'ageAtEvent', child.age_at_event,
            'status', registration_child.participation_status,
            'unitPriceCents', registration_child.unit_price_cents
          ) order by registration_child.created_at, registration_child.id)
          from app_private.registration_children registration_child
          join app_private.children child on child.id = registration_child.child_id
          where registration_child.registration_id = registration.id
        ), '[]'::jsonb),
        'changeRequests', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', change_request.id,
            'kind', replace(change_request.category, 'registration_', ''),
            'status', change_request.status,
            'description', change_request.safe_description,
            'createdAt', change_request.created_at,
            'updatedAt', change_request.updated_at
          ) order by change_request.created_at desc)
          from app_private.support_cases change_request
          where change_request.registration_id = registration.id
            and change_request.reporter = actor
        ), '[]'::jsonb),
        'payment', (
          select jsonb_build_object('status', payment.status, 'amountCents', payment.amount_cents, 'externalUrl', payment.external_url, 'version', payment.version)
          from app_private.payment_requests payment where payment.registration_id = registration.id order by payment.created_at desc limit 1
        )
      ) end
    )
    from app_private.household_members member
    join app_private.households household on household.id = member.household_id
    left join app_private.registration_drafts draft on draft.household_id = household.id and draft.event_id = v_event.id
    left join lateral (
      select candidate.*
      from app_private.registrations candidate
      where candidate.household_id = household.id and candidate.event_id = v_event.id
      order by (candidate.status <> 'cancelled') desc, candidate.created_at desc
      limit 1
    ) registration on true
    where member.user_id = actor and member.revoked_at is null
    order by member.accepted_at
    limit 1
  );
end;
$$;

create or replace function api.registration_request_change(
  _registration_id uuid,
  _request_kind text,
  _description text,
  _registration_child_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  registration app_private.registrations;
  event_record app_private.events;
  created app_private.support_cases;
  normalized_kind text := trim(coalesce(_request_kind, ''));
begin
  select * into registration from app_private.registrations where id = _registration_id for update;
  if registration.id is null or registration.status <> 'submitted'
     or not app_private.is_household_member(registration.household_id, actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  select * into event_record from app_private.events where id = registration.event_id;
  if normalized_kind not in ('correction', 'remove_child', 'cancellation')
     or char_length(trim(coalesce(_description, ''))) not between 10 and 1000 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if normalized_kind = 'remove_child' and not exists (
    select 1 from app_private.registration_children child
    where child.id = _registration_child_id and child.registration_id = registration.id and child.participation_status = 'active'
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if normalized_kind <> 'remove_child' and _registration_child_id is not null then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if exists (
    select 1 from app_private.support_cases existing
    where existing.registration_id = registration.id
      and existing.reporter = actor
      and existing.category = 'registration_' || normalized_kind
      and existing.status in ('open', 'acknowledged')
      and coalesce(existing.request_payload ->> 'registrationChildId', '') = coalesce(_registration_child_id::text, '')
  ) then raise exception 'REQUEST_ALREADY_OPEN' using errcode = '23505'; end if;

  insert into app_private.support_cases(event_id, registration_id, category, reporter, safe_description, request_payload)
  values (
    registration.event_id,
    registration.id,
    'registration_' || normalized_kind,
    actor,
    trim(_description),
    jsonb_strip_nulls(jsonb_build_object(
      'registrationChildId', _registration_child_id,
      'requestedAfterDeadline', event_record.change_deadline is not null and event_record.change_deadline <= now()
    ))
  ) returning * into created;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'registration.change_requested', 'support_case', created.id,
    jsonb_build_object('kind', normalized_kind, 'afterDeadline', event_record.change_deadline is not null and event_record.change_deadline <= now()));
  return jsonb_build_object(
    'id', created.id,
    'status', created.status,
    'kind', normalized_kind,
    'requestedAfterDeadline', event_record.change_deadline is not null and event_record.change_deadline <= now()
  );
end;
$$;

create or replace function api.admin_registration_changes_snapshot(_event_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare actor uuid := auth.uid(); v_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not (
    app_private.has_capability(v_event_id, 'event_admin', actor)
    or app_private.has_capability(v_event_id, 'registration_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', change_request.id,
      'version', change_request.version,
      'status', change_request.status,
      'kind', replace(change_request.category, 'registration_', ''),
      'description', change_request.safe_description,
      'createdAt', change_request.created_at,
      'registrationId', registration.id,
      'registrationReference', registration.reference,
      'registrationVersion', registration.version,
      'registrationStatus', registration.status,
      'householdLabel', household.label,
      'registrationChildId', nullif(change_request.request_payload ->> 'registrationChildId', ''),
      'childName', child.first_name,
      'requestedAfterDeadline', coalesce((change_request.request_payload ->> 'requestedAfterDeadline')::boolean, false)
    ) order by change_request.created_at desc)
    from app_private.support_cases change_request
    join app_private.registrations registration on registration.id = change_request.registration_id
    join app_private.households household on household.id = registration.household_id
    left join app_private.registration_children registration_child
      on registration_child.id = nullif(change_request.request_payload ->> 'registrationChildId', '')::uuid
    left join app_private.children child on child.id = registration_child.child_id
    where change_request.event_id = v_event_id and change_request.category like 'registration_%'
  ), '[]'::jsonb);
end;
$$;

create or replace function api.admin_decide_registration_change(
  _case_id uuid,
  _expected_case_version integer,
  _decision text,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  change_request app_private.support_cases;
  registration app_private.registrations;
  payment app_private.payment_requests;
  registration_child app_private.registration_children;
  normalized_decision text := trim(coalesce(_decision, ''));
  request_kind text;
  active_before integer;
  active_after integer;
  amount_before integer;
  amount_after integer;
  collected_cents integer := 0;
  next_payment_status app_private.payment_status;
begin
  select * into change_request from app_private.support_cases where id = _case_id for update;
  if change_request.id is null or change_request.registration_id is null
     or change_request.status not in ('open', 'acknowledged') then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  if change_request.version <> _expected_case_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not (
    app_private.has_capability(change_request.event_id, 'event_admin', actor)
    or app_private.has_capability(change_request.event_id, 'registration_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500
     or normalized_decision not in ('apply', 'close', 'reject') then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  request_kind := replace(change_request.category, 'registration_', '');
  if normalized_decision = 'apply' and request_kind not in ('remove_child', 'cancellation') then
    raise exception 'MANUAL_CORRECTION_REQUIRED' using errcode = '23514';
  end if;
  if normalized_decision = 'close' and request_kind <> 'correction' then
    raise exception 'INVALID_TRANSITION' using errcode = '23514';
  end if;

  if normalized_decision = 'reject' then
    update app_private.support_cases set status = 'closed', updated_at = now(), version = version + 1
    where id = change_request.id returning * into change_request;
    insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (change_request.event_id, actor, 'registration.change_rejected', 'support_case', change_request.id,
      jsonb_build_object('kind', request_kind, 'reason', left(trim(_reason), 500)));
    return jsonb_build_object('id', change_request.id, 'status', change_request.status, 'applied', false, 'version', change_request.version);
  end if;

  if normalized_decision = 'close' then
    update app_private.support_cases set status = 'resolved', updated_at = now(), version = version + 1
    where id = change_request.id returning * into change_request;
    insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (change_request.event_id, actor, 'registration.correction_resolved', 'support_case', change_request.id,
      jsonb_build_object('reason', left(trim(_reason), 500)));
    return jsonb_build_object('id', change_request.id, 'status', change_request.status, 'applied', false, 'version', change_request.version);
  end if;

  if not (
    app_private.has_capability(change_request.event_id, 'event_admin', actor)
    or app_private.has_capability(change_request.event_id, 'payments_manage', actor)
  ) then raise exception 'PAYMENTS_CAPABILITY_REQUIRED' using errcode = '42501'; end if;
  select * into registration from app_private.registrations where id = change_request.registration_id for update;
  if registration.id is null or registration.status <> 'submitted' then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if exists (
    select 1
    from app_private.group_registrations assignment
    join app_private.group_runs run on run.group_id = assignment.group_id
    where assignment.registration_id = registration.id and run.started_at is not null
  ) then raise exception 'RUN_ALREADY_STARTED' using errcode = '23514'; end if;

  select count(*)::integer,
         coalesce(sum(child.unit_price_cents), 0)::integer
    into active_before, amount_before
  from app_private.registration_children child
  where child.registration_id = registration.id and child.participation_status = 'active';

  if request_kind = 'remove_child' then
    if active_before <= 1 then raise exception 'USE_CANCELLATION' using errcode = '23514'; end if;
    select * into registration_child
    from app_private.registration_children child
    where child.id = nullif(change_request.request_payload ->> 'registrationChildId', '')::uuid
      and child.registration_id = registration.id and child.participation_status = 'active'
    for update;
    if registration_child.id is null then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
    update app_private.registration_children set participation_status = 'cancelled' where id = registration_child.id;
    update app_private.children set archived_at = now(), version = version + 1 where id = registration_child.child_id;
  else
    update app_private.registration_children set participation_status = 'cancelled'
    where registration_id = registration.id and participation_status = 'active';
    update app_private.children set archived_at = now(), version = version + 1
    where id in (select child_id from app_private.registration_children where registration_id = registration.id);
    update app_private.together_memberships set left_at = now()
    where registration_id = registration.id and left_at is null;
    update app_private.group_registrations set superseded_at = now()
    where registration_id = registration.id and superseded_at is null;
  end if;

  select count(*)::integer,
         coalesce(sum(child.unit_price_cents), 0)::integer
    into active_after, amount_after
  from app_private.registration_children child
  where child.registration_id = registration.id and child.participation_status = 'active';
  update app_private.registrations
  set status = case when request_kind = 'cancellation' then 'cancelled'::app_private.registration_status else status end,
      price_snapshot_cents = amount_after,
      updated_at = now(),
      version = version + 1
  where id = registration.id returning * into registration;
  insert into app_private.registration_revisions(registration_id, version, changed_by, change_type, totals_before, totals_after)
  values (
    registration.id,
    registration.version,
    actor,
    request_kind,
    jsonb_build_object('childCount', active_before, 'amountCents', amount_before),
    jsonb_build_object('childCount', active_after, 'amountCents', amount_after)
  );

  select * into payment from app_private.payment_requests request
  where request.registration_id = registration.id order by request.created_at desc limit 1 for update;
  if payment.id is not null then
    select coalesce(sum(entry.amount_cents) filter (where entry.entry_type in ('payment', 'refund')), 0)::integer
      into collected_cents from app_private.payment_entries entry where entry.request_id = payment.id;
    next_payment_status := case
      when collected_cents > amount_after then 'refund_due'::app_private.payment_status
      when amount_after = 0 then 'waived'::app_private.payment_status
      when collected_cents = amount_after then 'confirmed'::app_private.payment_status
      when collected_cents > 0 then 'partial'::app_private.payment_status
      when payment.external_url is null then 'awaiting_link'::app_private.payment_status
      else 'awaiting_payment'::app_private.payment_status
    end;
    update app_private.payment_requests
    set amount_cents = amount_after, status = next_payment_status, updated_at = now(), version = version + 1
    where id = payment.id returning * into payment;
  end if;
  update app_private.support_cases set status = 'resolved', updated_at = now(), version = version + 1
  where id = change_request.id returning * into change_request;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'registration.change_applied', 'registration', registration.id,
    jsonb_build_object(
      'kind', request_kind,
      'childCountBefore', active_before,
      'childCountAfter', active_after,
      'amountBeforeCents', amount_before,
      'amountAfterCents', amount_after,
      'refundDueCents', greatest(collected_cents - amount_after, 0),
      'reason', left(trim(_reason), 500)
    ));
  return jsonb_build_object(
    'id', change_request.id,
    'status', change_request.status,
    'applied', true,
    'kind', request_kind,
    'registrationStatus', registration.status,
    'registrationVersion', registration.version,
    'amountCents', amount_after,
    'paymentStatus', payment.status,
    'refundDueCents', greatest(collected_cents - amount_after, 0),
    'version', change_request.version
  );
end;
$$;

revoke execute on function api.registration_request_change(uuid, text, text, uuid) from public, anon;
revoke execute on function api.admin_registration_changes_snapshot(text) from public, anon;
revoke execute on function api.admin_decide_registration_change(uuid, integer, text, text) from public, anon;
grant execute on function api.registration_request_change(uuid, text, text, uuid) to authenticated;
grant execute on function api.admin_registration_changes_snapshot(text) to authenticated;
grant execute on function api.admin_decide_registration_change(uuid, integer, text, text) to authenticated;
