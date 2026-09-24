-- New child-level Tikkies are deliberately scoped to one registration.
alter function api.admin_child_payment_publish(text, jsonb, uuid, text, text, text)
  set schema app_private;
alter function app_private.admin_child_payment_publish(text, jsonb, uuid, text, text, text)
  rename to admin_child_payment_publish_before_registration_scope;
revoke all on function app_private.admin_child_payment_publish_before_registration_scope(text, jsonb, uuid, text, text, text)
  from public, anon, authenticated;

create function api.admin_child_payment_publish(
  _event_slug text,
  _children jsonb,
  _anchor_child_id uuid,
  _external_url text,
  _reason text,
  _idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  target_event_id uuid;
  registration_count integer;
begin
  select id into target_event_id
  from app_private.events
  where slug = _event_slug;

  if target_event_id is null
     or not (
       app_private.has_capability(target_event_id, 'payments_manage', actor)
       or app_private.has_capability(target_event_id, 'event_admin', actor)
     ) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  if _children is null or jsonb_typeof(_children) <> 'array' then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;

  select count(distinct registration_id)
  into registration_count
  from app_private.registration_children
  where event_id = target_event_id
    and child_id in (
      select (item->>'id')::uuid
      from jsonb_array_elements(_children) item
    );

  if registration_count <> 1 then
    raise exception 'CHILDREN_MUST_SHARE_REGISTRATION' using errcode = '23514';
  end if;

  return app_private.admin_child_payment_publish_before_registration_scope(
    _event_slug,
    _children,
    _anchor_child_id,
    _external_url,
    _reason,
    _idempotency_key
  );
end;
$$;

revoke all on function api.admin_child_payment_publish(text, jsonb, uuid, text, text, text) from public, anon;
grant execute on function api.admin_child_payment_publish(text, jsonb, uuid, text, text, text) to authenticated;

-- Organizers decide whether a parent-reported Tikkie is still unpaid without entering a free-text audit reason.
create function api.admin_child_payment_mark_unpaid(
  _batch_id uuid,
  _expected_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  batch app_private.child_payment_batches;
begin
  select *
  into batch
  from app_private.child_payment_batches
  where id = _batch_id;

  if batch.id is null
     or not (
       app_private.has_capability(batch.event_id, 'payments_manage', actor)
       or app_private.has_capability(batch.event_id, 'event_admin', actor)
     ) then
    raise exception 'NOT_AUTHORIZED' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('payment-batch:' || batch.event_id, 0));
  perform 1
  from app_private.payment_requests
  where id in (
    select payment_request_id
    from app_private.child_payment_members
    where batch_id = batch.id
  )
  order by id
  for update;
  perform 1
  from app_private.registration_children
  where child_payment_batch_id = batch.id
  order by child_id
  for update;

  select *
  into batch
  from app_private.child_payment_batches
  where id = _batch_id
  for update;

  if batch.version is distinct from _expected_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  if batch.status <> 'reported'
     or app_private.child_payment_batch_payload(batch.id)->>'status' = 'needs_review' then
    raise exception 'INVALID_TRANSITION' using errcode = '23514';
  end if;

  update app_private.child_payment_batches
  set status = 'awaiting_payment',
      version = version + 1
  where id = batch.id
  returning * into batch;

  update app_private.registration_children
  set payment_version = payment_version + 1
  where child_payment_batch_id = batch.id;

  insert into app_private.audit_events(
    event_id,
    actor_id,
    action,
    resource_type,
    resource_id,
    minimal_change
  ) values (
    batch.event_id,
    actor,
    'payment.child_marked_unpaid',
    'child_payment_batch',
    batch.id,
    jsonb_build_object('from', 'reported', 'to', 'awaiting_payment')
  );

  return app_private.child_payment_batch_payload(batch.id);
end;
$$;

revoke all on function api.admin_child_payment_mark_unpaid(uuid, integer) from public, anon;
grant execute on function api.admin_child_payment_mark_unpaid(uuid, integer) to authenticated;
