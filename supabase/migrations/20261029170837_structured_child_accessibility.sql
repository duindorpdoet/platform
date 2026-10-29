-- Keep the established public registration/parent authorization, payment and
-- publication guards. Structured mobility is a separate, explicit choice;
-- existing free text and historical children are never reclassified here.

CREATE OR REPLACE FUNCTION api.registration_submit(_event_slug text, _terms_version text, _privacy_version text, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  event_record app_private.events;
  v_household_id uuid;
  draft_record app_private.registration_drafts;
  registration_record app_private.registrations;
  child jsonb;
  child_count integer;
  total integer;
  receipt app_private.command_receipts;
  actor_email text;
  requested_together_code text;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into event_record from app_private.events where slug = _event_slug for update;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if not coalesce((event_record.settings ->> 'groupRegistrationOpen')::boolean, false)
     or (event_record.registration_open_at is not null and event_record.registration_open_at > now())
     or (event_record.registration_close_at is not null and event_record.registration_close_at <= now()) then
    raise exception 'REGISTRATION_CLOSED' using errcode = 'P0001';
  end if;

  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'registration.submit' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;

  select household.id into v_household_id
  from app_private.household_members member
  join app_private.households household on household.id = member.household_id
  where member.user_id = actor and member.revoked_at is null
  order by member.accepted_at
  limit 1;
  if v_household_id is null then raise exception 'HOUSEHOLD_REQUIRED' using errcode = '23514'; end if;

  select * into draft_record from app_private.registration_drafts
  where app_private.registration_drafts.event_id = event_record.id
    and app_private.registration_drafts.household_id = v_household_id
  for update;
  if draft_record.id is null then raise exception 'DRAFT_REQUIRED' using errcode = '23514'; end if;
  if jsonb_typeof(draft_record.payload -> 'children') <> 'array' then raise exception 'CHILDREN_REQUIRED' using errcode = '23514'; end if;
  child_count := jsonb_array_length(draft_record.payload -> 'children');
  if child_count < 1 then raise exception 'EMPTY_REGISTRATION' using errcode = '23514'; end if;
  if (select count(*) from app_private.registration_children where event_id = event_record.id and participation_status = 'active') + child_count > coalesce((event_record.settings ->> 'maxChildren')::integer, 300) then
    raise exception 'EVENT_CAPACITY_REACHED' using errcode = '23514';
  end if;

  requested_together_code := nullif(upper(trim(coalesce(draft_record.payload ->> 'togetherCode', ''))), '');
  if requested_together_code is not null and requested_together_code !~ '^[A-HJ-NP-Z2-9]{4}$' then
    raise exception 'INVALID_TOGETHER_CODE' using errcode = '22023';
  end if;
  total := child_count * event_record.price_cents;

  select * into registration_record from app_private.registrations
  where app_private.registrations.event_id = event_record.id
    and app_private.registrations.household_id = v_household_id
    and status <> 'cancelled'
  for update;
  if registration_record.id is null then
    insert into app_private.registrations(
      event_id, household_id, status, reference, submitted_at, terms_version, terms_accepted_at,
      privacy_version, marketing_consent, price_snapshot_cents
    ) values (
      event_record.id, v_household_id, 'submitted',
      upper('DPH-' || extract(year from event_record.local_date)::text || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
      now(), _terms_version, now(), _privacy_version,
      coalesce((draft_record.payload ->> 'marketingConsent')::boolean, false), total
    ) returning * into registration_record;

    for child in select value from jsonb_array_elements(draft_record.payload -> 'children') loop
      if nullif(trim(child ->> 'name'), '') is null then raise exception 'VALIDATION_ERROR' using errcode = '22023'; end if;
      if child ? 'stepFreeRequired' and jsonb_typeof(child -> 'stepFreeRequired') not in ('boolean', 'null') then
        raise exception 'INVALID_ACCESSIBILITY_REQUIREMENT' using errcode = '22023';
      end if;
      with inserted_child as (
        insert into app_private.children(household_id, first_name, age_at_event, age_band, accessibility_note, step_free_required)
        values (
          v_household_id,
          trim(child ->> 'name'),
          case when child ->> 'age' ~ '^[0-9]{1,2}$' then (child ->> 'age')::smallint else null end,
          nullif(trim(child ->> 'ageBand'), ''),
          nullif(trim(child ->> 'accessibilityNote'), ''),
          (child ->> 'stepFreeRequired')::boolean
        ) returning id
      )
      insert into app_private.registration_children(event_id, registration_id, child_id, unit_price_cents)
      select event_record.id, registration_record.id, id, event_record.price_cents from inserted_child;
    end loop;

    perform app_private.attach_registration_to_together_party(registration_record.id, requested_together_code);

    insert into app_private.payment_requests(registration_id, purpose, amount_cents, reference, status)
    values (registration_record.id, 'event_registration', total, registration_record.reference, 'awaiting_link');

    select email into actor_email from auth.users where id = actor;
    insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
    values (
      'registration:' || registration_record.id::text || ':received:' || actor::text,
      'registration_received', actor::text, actor_email,
      jsonb_build_object(
        'reference', registration_record.reference,
        'childCount', child_count,
        'amountCents', total,
        'paymentStatus', 'awaiting_link',
        'togetherCode', registration_record.together_code
      )
    );
    insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
    values (event_record.id, actor, 'registration.submitted', 'registration', registration_record.id, jsonb_build_object('childCount', child_count, 'amountCents', total));

    update app_private.registration_drafts
    set payload = payload - 'togetherCode' - 'togetherPreference', version = version + 1
    where id = draft_record.id;
  end if;

  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (
    actor, 'registration.submit', _idempotency_key, _request_hash,
    jsonb_build_object(
      'id', registration_record.id,
      'reference', registration_record.reference,
      'status', registration_record.status,
      'priceCents', registration_record.price_snapshot_cents,
      'togetherCode', registration_record.together_code
    ),
    now() + interval '30 days'
  ) returning * into receipt;
  return receipt.safe_result;
end;
$function$;


-- A distinct six-argument overload keeps existing clients compatible, without
-- optional arguments that make PostgREST function resolution ambiguous.
create function api.registration_child_add(
  _registration_id uuid,
  _expected_registration_version integer,
  _first_name text,
  _age_at_event integer,
  _accessibility_note text,
  _step_free_required boolean
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  result jsonb;
  v_child_id uuid;
  v_event_id uuid;
begin
  result := api.registration_child_add(_registration_id, _expected_registration_version, _first_name, _age_at_event, _accessibility_note);
  select rc.child_id, rc.event_id into v_child_id, v_event_id
  from app_private.registration_children rc
  where rc.id = (result ->> 'registrationChildId')::uuid
    and rc.registration_id = _registration_id;
  if v_child_id is null then
    raise exception 'REGISTRATION_CHILD_NOT_FOUND' using errcode = 'P0002';
  end if;
  update app_private.children set step_free_required = _step_free_required where id = v_child_id;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, auth.uid(), 'registration.child_accessibility_recorded', 'child', v_child_id,
    jsonb_build_object('stepFreeRequired', _step_free_required));
  return result;
end;
$$;
revoke all on function api.registration_child_add(uuid,integer,text,integer,text,boolean) from public,anon;
grant execute on function api.registration_child_add(uuid,integer,text,integer,text,boolean) to authenticated;

-- Enrich the common private base; existing wrappers still add current child
-- payment/removal rights and retain the event-specific household resolution.
do $$
declare
  original text;
  updated text;
begin
  select pg_get_functiondef('app_private.registration_snapshot_before_group_capacity(text)'::regprocedure) into original;
  updated := replace(original,
    $find$'ageAtEvent', child.age_at_event,$find$,
    $replacement$'ageAtEvent', child.age_at_event,
            'accessibilityNote', child.accessibility_note,
            'stepFreeRequired', child.step_free_required,$replacement$);
  if updated = original then raise exception 'REGISTRATION_SNAPSHOT_ACCESSIBILITY_PATCH_MISSING'; end if;
  execute updated;
end;
$$;
