-- Every registration receives a short, non-personal code. The sequence is
-- mapped through a bijection over 32^4 values, so concurrent submissions
-- cannot collide while the displayed codes do not reveal registration order.
create sequence app_private.together_code_sequence
  as bigint
  minvalue 0
  maxvalue 1048575
  start with 0
  no cycle;

create function app_private.next_together_code()
returns text
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  value bigint := mod(nextval('app_private.together_code_sequence'::regclass) * 741103 + 182451, 1048576);
  generated text := '';
begin
  for position in 1..4 loop
    generated := substr(alphabet, mod(value, 32)::integer + 1, 1) || generated;
    value := value / 32;
  end loop;
  return generated;
end;
$$;

revoke all on sequence app_private.together_code_sequence from public, anon, authenticated;
revoke execute on function app_private.next_together_code() from public, anon, authenticated;

alter table app_private.registrations add column together_code text;

update app_private.registrations
set together_code = app_private.next_together_code()
where together_code is null;

alter table app_private.registrations
  alter column together_code set default app_private.next_together_code(),
  alter column together_code set not null,
  add constraint registrations_together_code_format
    check (together_code ~ '^[A-HJ-NP-Z2-9]{4}$'),
  add constraint registrations_together_code_unique unique (together_code);

-- Free-text together preferences and visitor-authored party labels are no
-- longer retained. Existing planner links remain intact.
update app_private.registration_drafts
set payload = (payload - 'togetherPreference' - 'togetherCode') || jsonb_build_object('togetherCode', ''),
    version = version + 1
where jsonb_typeof(payload) = 'object'
  and (payload ? 'togetherPreference' or payload ? 'togetherCode');

update app_private.together_parties
set public_label = 'Samenloop ' || upper(substr(replace(id::text, '-', ''), 1, 6));

do $$
declare
  registration_record record;
  party_id uuid;
begin
  for registration_record in
    select registration.id, registration.event_id, registration.household_id, registration.together_code
    from app_private.registrations registration
    where registration.status = 'submitted'
      and not exists (
        select 1
        from app_private.together_memberships membership
        where membership.registration_id = registration.id and membership.left_at is null
      )
  loop
    insert into app_private.together_parties(
      event_id, public_label, creator_household_id, invite_token_hash, expires_at
    ) values (
      registration_record.event_id,
      'Samenloopcode ' || registration_record.together_code,
      registration_record.household_id,
      extensions.digest(convert_to('registration:' || registration_record.id::text, 'utf8'), 'sha256'),
      now() + interval '10 years'
    ) returning id into party_id;

    insert into app_private.together_memberships(party_id, registration_id)
    values (party_id, registration_record.id);
  end loop;
end;
$$;

create function app_private.attach_registration_to_together_party(
  _registration_id uuid,
  _requested_code text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  registration_record app_private.registrations;
  normalized_code text := nullif(upper(trim(coalesce(_requested_code, ''))), '');
  party_id uuid;
begin
  select * into registration_record
  from app_private.registrations
  where id = _registration_id
  for update;

  if registration_record.id is null then
    raise exception 'REGISTRATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  select membership.party_id into party_id
  from app_private.together_memberships membership
  where membership.registration_id = registration_record.id and membership.left_at is null;
  if party_id is not null then return party_id; end if;

  if normalized_code is not null and normalized_code !~ '^[A-HJ-NP-Z2-9]{4}$' then
    raise exception 'INVALID_TOGETHER_CODE' using errcode = '22023';
  end if;

  if normalized_code is not null then
    select membership.party_id into party_id
    from app_private.registrations target
    join app_private.together_memberships membership
      on membership.registration_id = target.id and membership.left_at is null
    join app_private.together_parties party
      on party.id = membership.party_id and party.locked_at is null
    where target.event_id = registration_record.event_id
      and target.status = 'submitted'
      and target.together_code = normalized_code
      and target.id <> registration_record.id
    for update of party;

    if party_id is null then
      raise exception 'INVALID_TOGETHER_CODE' using errcode = '22023';
    end if;
  else
    insert into app_private.together_parties(
      event_id, public_label, creator_household_id, invite_token_hash, expires_at
    ) values (
      registration_record.event_id,
      'Samenloopcode ' || registration_record.together_code,
      registration_record.household_id,
      extensions.digest(convert_to('registration:' || registration_record.id::text, 'utf8'), 'sha256'),
      now() + interval '10 years'
    ) returning id into party_id;
  end if;

  insert into app_private.together_memberships(party_id, registration_id)
  values (party_id, registration_record.id);
  return party_id;
end;
$$;

revoke execute on function app_private.attach_registration_to_together_party(uuid, text) from public, anon, authenticated;

create or replace function api.registration_save_draft(
  _event_slug text,
  _payload jsonb,
  _expected_version integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
  v_household_id uuid;
  draft_record app_private.registration_drafts;
  adult_name text := nullif(trim(_payload #>> '{adult,name}'), '');
  requested_together_code text;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if jsonb_typeof(_payload) <> 'object' or jsonb_typeof(_payload -> 'adult') <> 'object' or adult_name is null then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  requested_together_code := upper(regexp_replace(trim(coalesce(_payload ->> 'togetherCode', '')), '[^A-Za-z0-9]', '', 'g'));
  if requested_together_code <> '' and requested_together_code !~ '^[A-HJ-NP-Z2-9]{4}$' then
    raise exception 'INVALID_TOGETHER_CODE' using errcode = '22023';
  end if;
  _payload := jsonb_set(
      _payload - 'togetherPreference' - 'togetherCode',
      '{adult}',
      (_payload -> 'adult') - 'householdLabel',
      true
    ) || jsonb_build_object('togetherCode', requested_together_code);

  select household.id into v_household_id
  from app_private.household_members member
  join app_private.households household on household.id = member.household_id
  where member.user_id = actor and member.revoked_at is null
  order by member.accepted_at
  limit 1;

  if v_household_id is null then
    v_household_id := gen_random_uuid();
    insert into app_private.households(id, label, primary_contact_user_id, phone)
    values (
      v_household_id,
      'Gezelschap ' || upper(substr(replace(v_household_id::text, '-', ''), 1, 6)),
      actor,
      nullif(trim(_payload #>> '{adult,phone}'), '')
    );
    insert into app_private.household_members(household_id, user_id, relation_role)
    values (v_household_id, actor, 'owner');
  else
    update app_private.households
    set phone = nullif(trim(_payload #>> '{adult,phone}'), ''),
        version = version + 1
    where id = v_household_id;
  end if;

  update app_private.profiles
  set display_name = adult_name, version = version + 1
  where user_id = actor;

  insert into app_private.registration_drafts(event_id, household_id, payload)
  values (v_event_id, v_household_id, _payload)
  on conflict (event_id, household_id) do update
    set payload = excluded.payload,
        version = app_private.registration_drafts.version + 1
    where _expected_version is null or app_private.registration_drafts.version = _expected_version
  returning * into draft_record;

  if draft_record.id is null then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  return jsonb_build_object('id', draft_record.id, 'version', draft_record.version, 'savedAt', draft_record.updated_at);
end;
$$;

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
        'togetherCode', registration.together_code,
        'togetherCount', coalesce((
          select count(*)
          from app_private.together_memberships own_membership
          join app_private.together_memberships party_member
            on party_member.party_id = own_membership.party_id and party_member.left_at is null
          join app_private.registrations party_registration
            on party_registration.id = party_member.registration_id and party_registration.status = 'submitted'
          where own_membership.registration_id = registration.id and own_membership.left_at is null
        ), 1),
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
          from app_private.payment_requests payment
          where payment.registration_id = registration.id
          order by payment.created_at desc
          limit 1
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

create or replace function api.registration_submit(
  _event_slug text,
  _terms_version text,
  _privacy_version text,
  _idempotency_key text,
  _request_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
      with inserted_child as (
        insert into app_private.children(household_id, first_name, age_at_event, age_band, accessibility_note)
        values (
          v_household_id,
          trim(child ->> 'name'),
          case when child ->> 'age' ~ '^[0-9]{1,2}$' then (child ->> 'age')::smallint else null end,
          nullif(trim(child ->> 'ageBand'), ''),
          nullif(trim(child ->> 'accessibilityNote'), '')
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
$$;

-- The old free-form group creator and post-registration join flow would let a
-- registration bypass the code selected during signup, so retire that API.
drop function api.together_snapshot(text);
drop function api.together_create(uuid, text);
drop function api.together_join(uuid, text);
drop function api.together_leave(uuid, text);

revoke execute on function api.registration_save_draft(text, jsonb, integer) from public, anon;
revoke execute on function api.registration_snapshot(text) from public, anon;
revoke execute on function api.registration_submit(text, text, text, text, text) from public, anon;
grant execute on function api.registration_save_draft(text, jsonb, integer) to authenticated;
grant execute on function api.registration_snapshot(text) to authenticated;
grant execute on function api.registration_submit(text, text, text, text, text) to authenticated;
