-- Complete three security-sensitive lifecycle gaps: addressed household access,
-- append-only refunds, and auditable portal credential rotation.

create or replace function api.household_access_snapshot(_event_slug text)
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  actor uuid := auth.uid();
  household_record record;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  select household.*, member.relation_role as actor_role
    into household_record
  from app_private.events event
  join app_private.registrations registration on registration.event_id = event.id and registration.status <> 'cancelled'
  join app_private.households household on household.id = registration.household_id
  join app_private.household_members member on member.household_id = household.id
    and member.user_id = actor and member.revoked_at is null
  where event.slug = _event_slug
  order by member.accepted_at
  limit 1;

  if household_record.id is null then return null; end if;

  return jsonb_build_object(
    'id', household_record.id,
    'label', household_record.label,
    'version', household_record.version,
    'canManage', household_record.actor_role = 'owner',
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'userId', member.user_id,
        'role', member.relation_role,
        'email', lower(users.email),
        'acceptedAt', member.accepted_at
      ) order by member.accepted_at)
      from app_private.household_members member
      join auth.users users on users.id = member.user_id
      where member.household_id = household_record.id and member.revoked_at is null
    ), '[]'::jsonb),
    'pendingInvites', case when household_record.actor_role = 'owner' then coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', invite.id,
        'recipientEmail', lower(invite.recipient_email),
        'expiresAt', invite.expires_at,
        'createdAt', invite.created_at
      ) order by invite.created_at desc)
      from app_private.household_invites invite
      where invite.household_id = household_record.id
        and invite.consumed_at is null and invite.revoked_at is null and invite.expires_at > now()
    ), '[]'::jsonb) else '[]'::jsonb end
  );
end;
$$;

create or replace function api.household_invite_create(
  _event_slug text,
  _recipient_email text,
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
  normalized_email text := lower(trim(_recipient_email));
  v_event_id uuid;
  v_household_id uuid;
  household_record app_private.households;
  invite app_private.household_invites;
  receipt app_private.command_receipts;
  invite_token text;
  actor_count integer;
  recipient_count integer;
  result jsonb;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or char_length(normalized_email) > 254 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if char_length(trim(coalesce(_idempotency_key, ''))) not between 8 and 200
     or char_length(trim(coalesce(_request_hash, ''))) not between 8 and 200 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  select event.id, household.id into v_event_id, v_household_id
  from app_private.events event
  join app_private.registrations registration on registration.event_id = event.id and registration.status <> 'cancelled'
  join app_private.households household on household.id = registration.household_id
  join app_private.household_members member on member.household_id = household.id
    and member.user_id = actor and member.relation_role = 'owner' and member.revoked_at is null
  where event.slug = _event_slug
  order by registration.created_at
  limit 1;
  if v_household_id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into household_record from app_private.households where id = v_household_id for update;

  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'household.inviteCreate' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;

  if exists (
    select 1 from app_private.household_members member
    join auth.users users on users.id = member.user_id
    where member.household_id = household_record.id and member.revoked_at is null and lower(users.email) = normalized_email
  ) then raise exception 'INVITE_NOT_AVAILABLE' using errcode = '23514'; end if;

  insert into app_private.rate_limit_buckets(scope, opaque_subject_hash, window_start, expires_at)
  values (
    'household_invite_actor',
    encode(extensions.digest(convert_to(actor::text, 'utf8'), 'sha256'), 'hex'),
    date_trunc('hour', now()),
    date_trunc('hour', now()) + interval '2 hours'
  )
  on conflict (scope, opaque_subject_hash, window_start)
  do update set count = app_private.rate_limit_buckets.count + 1
  returning count into actor_count;
  insert into app_private.rate_limit_buckets(scope, opaque_subject_hash, window_start, expires_at)
  values (
    'household_invite_recipient',
    encode(extensions.digest(convert_to(normalized_email, 'utf8'), 'sha256'), 'hex'),
    date_trunc('hour', now()),
    date_trunc('hour', now()) + interval '2 hours'
  )
  on conflict (scope, opaque_subject_hash, window_start)
  do update set count = app_private.rate_limit_buckets.count + 1
  returning count into recipient_count;
  if actor_count > 5 or recipient_count > 3 then raise exception 'RATE_LIMITED' using errcode = 'P0001'; end if;

  update app_private.household_invites
  set revoked_at = now()
  where household_id = household_record.id and lower(recipient_email) = normalized_email
    and consumed_at is null and revoked_at is null;

  invite_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into app_private.household_invites(household_id, recipient_email, token_hash, invited_by, expires_at)
  values (
    household_record.id,
    normalized_email,
    extensions.digest(convert_to(invite_token, 'utf8'), 'sha256'),
    actor,
    now() + interval '7 days'
  ) returning * into invite;
  update app_private.households set version = version + 1 where id = household_record.id returning * into household_record;

  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values (
    'household-invite:' || invite.id::text,
    'household_invite',
    'household_invite:' || invite.id::text,
    normalized_email,
    jsonb_build_object(
      'householdLabel', household_record.label,
      'inviteToken', invite_token,
      'actionPath', '/mijn-inschrijving?uitnodiging=' || invite_token,
      'expiresAt', invite.expires_at
    )
  );
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'household.invite_created', 'household_invite', invite.id, jsonb_build_object('expiresAt', invite.expires_at));

  result := jsonb_build_object('id', invite.id, 'expiresAt', invite.expires_at, 'householdVersion', household_record.version);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'household.inviteCreate', _idempotency_key, _request_hash, result, now() + interval '30 days');
  return result;
end;
$$;

create or replace function api.household_invite_accept(_invite_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  actor_email text;
  invite app_private.household_invites;
  v_event_id uuid;
  v_household_id uuid;
  household_record app_private.households;
begin
  if actor is null or char_length(trim(coalesce(_invite_token, ''))) <> 64 then
    raise exception 'INVITE_NOT_AVAILABLE' using errcode = '22023';
  end if;
  select lower(email) into actor_email from auth.users where id = actor and email_confirmed_at is not null;
  if actor_email is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;

  select * into invite from app_private.household_invites
  where token_hash = extensions.digest(convert_to(trim(_invite_token), 'utf8'), 'sha256')
  for update;
  if invite.id is null or invite.revoked_at is not null or invite.consumed_at is not null or invite.expires_at <= now() then
    raise exception 'INVITE_NOT_AVAILABLE' using errcode = '23514';
  end if;
  if lower(invite.recipient_email) <> actor_email then raise exception 'RECIPIENT_MISMATCH' using errcode = '42501'; end if;

  select event.id, household.id into v_event_id, v_household_id
  from app_private.households household
  join app_private.registrations registration on registration.household_id = household.id and registration.status <> 'cancelled'
  join app_private.events event on event.id = registration.event_id
  where household.id = invite.household_id
  order by registration.created_at
  limit 1;
  if v_household_id is null then raise exception 'INVITE_NOT_AVAILABLE' using errcode = '23514'; end if;
  select * into household_record from app_private.households where id = v_household_id for update;

  if exists (
    select 1 from app_private.household_members member
    join app_private.registrations registration on registration.household_id = member.household_id
    where member.user_id = actor and member.revoked_at is null and registration.event_id = v_event_id
      and member.household_id <> invite.household_id and registration.status <> 'cancelled'
  ) then raise exception 'HOUSEHOLD_CONFLICT' using errcode = '23514'; end if;

  insert into app_private.household_members(household_id, user_id, relation_role)
  values (invite.household_id, actor, 'adult');
  update app_private.household_invites set consumed_at = now() where id = invite.id;
  update app_private.households set version = version + 1 where id = invite.household_id returning * into household_record;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id)
  values (v_event_id, actor, 'household.invite_accepted', 'household_invite', invite.id);
  return jsonb_build_object('accepted', true, 'householdId', invite.household_id, 'householdVersion', household_record.version);
end;
$$;

create or replace function api.household_invite_revoke(
  _invite_id uuid,
  _expected_household_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  invite app_private.household_invites;
  household_record app_private.households;
  v_event_id uuid;
begin
  if char_length(trim(coalesce(_reason, ''))) not between 5 and 300 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select * into invite from app_private.household_invites where id = _invite_id for update;
  if invite.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into household_record from app_private.households where id = invite.household_id for update;
  if household_record.version <> _expected_household_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not exists (select 1 from app_private.household_members where household_id = invite.household_id and user_id = actor and relation_role = 'owner' and revoked_at is null)
     then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if invite.consumed_at is not null or invite.revoked_at is not null then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
  update app_private.household_invites set revoked_at = now() where id = invite.id;
  update app_private.households set version = version + 1 where id = invite.household_id returning * into household_record;
  select registration.event_id into v_event_id from app_private.registrations registration where registration.household_id = invite.household_id and registration.status <> 'cancelled' order by created_at limit 1;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'household.invite_revoked', 'household_invite', invite.id, jsonb_build_object('reason', left(_reason, 300)));
  return jsonb_build_object('revoked', true, 'householdVersion', household_record.version);
end;
$$;

create or replace function api.household_member_revoke(
  _event_slug text,
  _member_user_id uuid,
  _expected_household_version integer,
  _reason text
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
  household_record app_private.households;
begin
  if char_length(trim(coalesce(_reason, ''))) not between 5 and 300 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select event.id, household.id into v_event_id, v_household_id
  from app_private.events event
  join app_private.registrations registration on registration.event_id = event.id and registration.status <> 'cancelled'
  join app_private.households household on household.id = registration.household_id
  join app_private.household_members owner on owner.household_id = household.id
    and owner.user_id = actor and owner.relation_role = 'owner' and owner.revoked_at is null
  where event.slug = _event_slug
  limit 1;
  if v_household_id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into household_record from app_private.households where id = v_household_id for update;
  if household_record.version <> _expected_household_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if _member_user_id = actor or _member_user_id = household_record.primary_contact_user_id then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
  update app_private.household_members
  set revoked_at = now(), revoked_by = actor
  where household_id = household_record.id and user_id = _member_user_id and relation_role = 'adult' and revoked_at is null;
  if not found then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  update app_private.households set version = version + 1 where id = household_record.id returning * into household_record;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'household.member_revoked', 'household', household_record.id, jsonb_build_object('reason', left(_reason, 300)));
  return jsonb_build_object('revoked', true, 'householdVersion', household_record.version);
end;
$$;

create or replace function api.payment_refund(
  _payment_request_id uuid,
  _amount_cents integer,
  _external_reference text,
  _reason text,
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
  payment app_private.payment_requests;
  registration app_private.registrations;
  receipt app_private.command_receipts;
  refundable_cents integer;
  remaining_cents integer;
  result jsonb;
begin
  select * into payment from app_private.payment_requests where id = _payment_request_id for update;
  if payment.id is null then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select * into registration from app_private.registrations where id = payment.registration_id;
  if registration.id is null or not app_private.has_capability(registration.event_id, 'payments_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'payment.refund' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  if _amount_cents <= 0 or char_length(trim(coalesce(_reason, ''))) not between 5 and 500
     or nullif(trim(coalesce(_external_reference, '')), '') is null then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if payment.status not in ('confirmed', 'partial', 'refund_due') then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;

  select coalesce(sum(entry.amount_cents), 0)::integer into refundable_cents
  from app_private.payment_entries entry where entry.request_id = payment.id;
  if refundable_cents < _amount_cents then raise exception 'REFUND_EXCEEDS_COLLECTED' using errcode = '23514'; end if;
  remaining_cents := refundable_cents - _amount_cents;

  insert into app_private.payment_entries(request_id, amount_cents, entry_type, checked_by, checked_at, external_reference, reason)
  values (payment.id, -_amount_cents, 'refund', actor, now(), trim(_external_reference), trim(_reason));
  update app_private.payment_requests
  set status = case when remaining_cents = 0 then 'refunded'::app_private.payment_status else 'refund_due'::app_private.payment_status end,
      version = version + 1
  where id = payment.id returning * into payment;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'payment.refunded', 'payment_request', payment.id, jsonb_build_object('amountCents', _amount_cents, 'remainingCents', remaining_cents, 'reason', left(_reason, 500)));
  result := jsonb_build_object('id', payment.id, 'status', payment.status, 'version', payment.version, 'refundedCents', _amount_cents, 'remainingCents', remaining_cents);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'payment.refund', _idempotency_key, _request_hash, result, now() + interval '1 year');
  return result;
end;
$$;

create or replace function api.admin_payments_snapshot(_event_slug text)
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  actor uuid := auth.uid();
  v_event_id uuid;
begin
  select id into v_event_id from app_private.events where slug = _event_slug;
  if v_event_id is null or not (
    app_private.has_capability(v_event_id, 'event_admin', actor)
    or app_private.has_capability(v_event_id, 'payments_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', payment.id,
      'reference', payment.reference,
      'registrationReference', registration.reference,
      'amountCents', payment.amount_cents,
      'netCollectedCents', coalesce(ledger.net_collected_cents, 0),
      'status', payment.status,
      'version', payment.version,
      'reportedAt', ledger.reported_at,
      'updatedAt', payment.updated_at
    ) order by payment.updated_at desc, payment.reference)
    from app_private.payment_requests payment
    join app_private.registrations registration on registration.id = payment.registration_id
    left join lateral (
      select
        coalesce(sum(entry.amount_cents) filter (where entry.entry_type <> 'reported'), 0)::integer as net_collected_cents,
        max(entry.created_at) filter (where entry.entry_type = 'reported') as reported_at
      from app_private.payment_entries entry where entry.request_id = payment.id
    ) ledger on true
    where registration.event_id = v_event_id
  ), '[]'::jsonb);
end;
$$;

create or replace function api.payment_confirm_versioned(
  _payment_request_id uuid,
  _expected_version integer,
  _amount_cents integer,
  _external_reference text,
  _reason text,
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
  payment app_private.payment_requests;
  registration app_private.registrations;
  receipt app_private.command_receipts;
  collected_before integer;
  collected_after integer;
  result jsonb;
begin
  select * into payment from app_private.payment_requests where id = _payment_request_id for update;
  if payment.id is null then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select * into registration from app_private.registrations where id = payment.registration_id;
  if registration.id is null or not app_private.has_capability(registration.event_id, 'payments_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'payment.confirmVersioned' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    return receipt.safe_result;
  end if;
  if payment.version <> _expected_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if payment.status in ('confirmed', 'refunded', 'waived') then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;
  if _amount_cents <= 0 or char_length(trim(coalesce(_reason, ''))) not between 5 and 500
     or nullif(trim(coalesce(_external_reference, '')), '') is null then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  select coalesce(sum(entry.amount_cents) filter (where entry.entry_type <> 'reported'), 0)::integer into collected_before
  from app_private.payment_entries entry where entry.request_id = payment.id;
  collected_after := collected_before + _amount_cents;
  insert into app_private.payment_entries(request_id, amount_cents, entry_type, checked_by, checked_at, external_reference, reason)
  values (payment.id, _amount_cents, 'payment', actor, now(), trim(_external_reference), trim(_reason));
  update app_private.payment_requests
  set status = case
        when collected_after = amount_cents then 'confirmed'::app_private.payment_status
        when collected_after < amount_cents then 'partial'::app_private.payment_status
        else 'refund_due'::app_private.payment_status
      end,
      version = version + 1
  where id = payment.id returning * into payment;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (registration.event_id, actor, 'payment.confirmed', 'payment_request', payment.id, jsonb_build_object('amountCents', _amount_cents, 'netCollectedCents', collected_after, 'reason', left(_reason, 500)));
  result := jsonb_build_object('id', payment.id, 'status', payment.status, 'version', payment.version, 'netCollectedCents', collected_after);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'payment.confirmVersioned', _idempotency_key, _request_hash, result, now() + interval '1 year');
  return result;
end;
$$;

create or replace function api.portal_rotate_credential(
  _portal_id uuid,
  _expected_portal_version integer,
  _reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  portal app_private.portals;
  credential app_private.portal_credentials;
  credential_token text;
  short_code text;
  next_version integer;
begin
  if char_length(trim(coalesce(_reason, ''))) not between 5 and 300 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select * into portal from app_private.portals where id = _portal_id for update;
  if portal.id is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if not exists (select 1 from app_private.portal_owners owner where owner.portal_id = portal.id and owner.user_id = actor and owner.revoked_at is null)
     and not app_private.has_capability(portal.event_id, 'portals_manage', actor) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  if portal.version <> _expected_portal_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if portal.approval_status <> 'approved' then raise exception 'INVALID_TRANSITION' using errcode = '23514'; end if;

  select coalesce(max(version), 0) + 1 into next_version from app_private.portal_credentials where portal_id = portal.id;
  credential_token := encode(extensions.gen_random_bytes(32), 'hex');
  short_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
  update app_private.portal_credentials set revoked_at = now() where portal_id = portal.id and revoked_at is null;
  insert into app_private.portal_credentials(portal_id, token_hash, short_code_hash, version, valid_from)
  values (
    portal.id,
    extensions.digest(convert_to(credential_token, 'utf8'), 'sha256'),
    extensions.digest(convert_to(short_code, 'utf8'), 'sha256'),
    next_version,
    now()
  ) returning * into credential;
  update app_private.portals set version = version + 1 where id = portal.id returning * into portal;
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (portal.event_id, actor, 'portal.credential_rotated', 'portal', portal.id, jsonb_build_object('credentialVersion', credential.version, 'reason', left(_reason, 300)));
  return jsonb_build_object(
    'portalId', portal.id,
    'portalVersion', portal.version,
    'credentialVersion', credential.version,
    'credential', credential_token,
    'shortCode', short_code
  );
end;
$$;

create or replace function app_private.block_unavailable_portal_visit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  portal_state app_private.portal_operation_status;
begin
  if new.status = 'visited' and old.status is distinct from 'visited' then
    select portal.operation_status into portal_state
    from app_private.run_stops run_stop
    join app_private.route_plan_stops plan_stop on plan_stop.id = run_stop.plan_stop_id
    join app_private.portals portal on portal.id = plan_stop.portal_id
    where run_stop.id = new.run_stop_id;
    if portal_state is distinct from 'open' then raise exception 'PORTAL_UNAVAILABLE' using errcode = '23514'; end if;
  end if;
  return new;
end;
$$;

create trigger stop_participant_statuses_portal_available
before update of status on app_private.stop_participant_statuses
for each row execute function app_private.block_unavailable_portal_visit();

create or replace function api.run_system_skip(
  _run_id uuid,
  _stop_id uuid,
  _expected_run_version integer,
  _reason text,
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
  run_record app_private.group_runs;
  stop_record app_private.run_stops;
  next_stop app_private.run_stops;
  receipt app_private.command_receipts;
  portal_state app_private.portal_operation_status;
  portal_id uuid;
  world_id uuid;
  v_event_id uuid;
  result jsonb;
begin
  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'run.systemSkip' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    select * into run_record from app_private.group_runs where id = _run_id;
    select walking_group.event_id into v_event_id from app_private.walking_groups walking_group where walking_group.id = run_record.group_id;
    if run_record.id is null or not (app_private.is_current_leader(run_record.group_id, actor) or app_private.has_capability(v_event_id, 'live_support', actor)) then
      raise exception 'NOT_AUTHORIZED' using errcode = '42501';
    end if;
    return receipt.safe_result;
  end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;

  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _stop_id or run_record.version <> _expected_run_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  select walking_group.event_id into v_event_id from app_private.walking_groups walking_group where walking_group.id = run_record.group_id;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not (app_private.is_current_leader(run_record.group_id, actor) or app_private.has_capability(v_event_id, 'live_support', actor)) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;
  select * into stop_record from app_private.run_stops where id = _stop_id and run_id = _run_id for update;
  if stop_record.id is null or stop_record.state <> 'active' then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  select portal.id, portal.world_id, portal.operation_status into portal_id, world_id, portal_state
  from app_private.route_plan_stops plan_stop
  join app_private.portals portal on portal.id = plan_stop.portal_id
  where plan_stop.id = stop_record.plan_stop_id;
  if portal_state <> 'closed' then raise exception 'PORTAL_NOT_CLOSED' using errcode = '23514'; end if;
  if exists (select 1 from app_private.stop_participant_statuses where run_stop_id = _stop_id and status = 'visited') then
    raise exception 'VISIT_ALREADY_RECORDED' using errcode = '23514';
  end if;

  update app_private.stop_participant_statuses
  set required_for_completion = false, exclusion_reason = 'system_portal_closed', reason = left(_reason, 500), version = version + 1, changed_by = actor
  where run_stop_id = _stop_id and required_for_completion;
  update app_private.run_stops
  set state = 'completed', outcome = 'system_skipped', completed_at = now(), completion_actor = actor,
      completion_reason = left(_reason, 500), version = version + 1
  where id = _stop_id;
  insert into app_private.group_seals(run_id, run_stop_id, world_id, outcome)
  values (_run_id, _stop_id, world_id, 'system_skipped');

  select * into next_stop from app_private.run_stops where run_id = _run_id and sequence = stop_record.sequence + 1 for update;
  if next_stop.id is null then
    update app_private.group_runs set status = 'completed', current_stop_id = null, finished_at = now(), version = version + 1
    where id = _run_id returning * into run_record;
    update app_private.walking_groups set status = 'completed', version = version + 1 where id = run_record.group_id;
  else
    update app_private.run_stops set state = 'active', opened_at = now(), version = version + 1 where id = next_stop.id;
    insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
    select next_stop.id, participant.id from app_private.run_participants participant
    where participant.run_id = _run_id and participant.attendance = 'present';
    update app_private.group_runs set current_stop_id = next_stop.id, version = version + 1
    where id = _run_id returning * into run_record;
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (_run_id, _stop_id, 'stop.system_skipped', actor, jsonb_build_object('portalId', portal_id, 'reason', left(_reason, 500)));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (v_event_id, actor, 'stop.system_skipped', 'group_run', _run_id, jsonb_build_object('stopId', _stop_id, 'portalId', portal_id, 'reason', left(_reason, 500)));
  result := jsonb_build_object('runId', _run_id, 'status', run_record.status, 'version', run_record.version, 'completedStopId', _stop_id, 'outcome', 'system_skipped', 'hasNextStop', next_stop.id is not null);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.systemSkip', _idempotency_key, _request_hash, result, now() + interval '2 days');
  return result;
end;
$$;

revoke execute on function app_private.block_unavailable_portal_visit() from public, anon, authenticated;

revoke execute on function api.household_access_snapshot(text) from public, anon;
revoke execute on function api.household_invite_create(text, text, text, text) from public, anon;
revoke execute on function api.household_invite_accept(text) from public, anon;
revoke execute on function api.household_invite_revoke(uuid, integer, text) from public, anon;
revoke execute on function api.household_member_revoke(text, uuid, integer, text) from public, anon;
revoke execute on function api.payment_refund(uuid, integer, text, text, text, text) from public, anon;
revoke execute on function api.admin_payments_snapshot(text) from public, anon;
revoke execute on function api.payment_confirm_versioned(uuid, integer, integer, text, text, text, text) from public, anon;
revoke execute on function api.payment_confirm(uuid, integer, text, text, text, text) from authenticated;
revoke execute on function api.portal_rotate_credential(uuid, integer, text) from public, anon;
revoke execute on function api.run_system_skip(uuid, uuid, integer, text, text, text) from public, anon;

grant execute on function api.household_access_snapshot(text) to authenticated;
grant execute on function api.household_invite_create(text, text, text, text) to authenticated;
grant execute on function api.household_invite_accept(text) to authenticated;
grant execute on function api.household_invite_revoke(uuid, integer, text) to authenticated;
grant execute on function api.household_member_revoke(text, uuid, integer, text) to authenticated;
grant execute on function api.payment_refund(uuid, integer, text, text, text, text) to authenticated;
grant execute on function api.admin_payments_snapshot(text) to authenticated;
grant execute on function api.payment_confirm_versioned(uuid, integer, integer, text, text, text, text) to authenticated;
grant execute on function api.portal_rotate_credential(uuid, integer, text) to authenticated;
grant execute on function api.run_system_skip(uuid, uuid, integer, text, text, text) to authenticated;
