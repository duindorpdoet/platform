-- Give payment e-mails the registration reference and exact amount per child.
-- The payment link itself remains available to only the designated household.

create or replace function app_private.enqueue_child_payment_email(_id uuid, _type text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  batch app_private.child_payment_batches;
  recipient record;
  batch_payload jsonb;
  registration_reference text;
  child_details jsonb;
begin
  select * into batch
  from app_private.child_payment_batches
  where id = _id;

  batch_payload := app_private.child_payment_batch_payload(batch.id);

  select registration.reference
  into registration_reference
  from app_private.child_payment_members member
  join app_private.registration_children registration_child on registration_child.id = member.registration_child_id
  join app_private.registrations registration on registration.id = registration_child.registration_id
  where member.batch_id = batch.id
    and registration_child.child_id = batch.anchor_child_id
  limit 1;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('name', child.first_name, 'amountCents', member.amount_cents)
      order by registration_child.created_at, child.id
    ),
    '[]'::jsonb
  )
  into child_details
  from app_private.child_payment_members member
  join app_private.registration_children registration_child on registration_child.id = member.registration_child_id
  join app_private.children child on child.id = registration_child.child_id
  where member.batch_id = batch.id;

  for recipient in
    select distinct user_account.id, lower(user_account.email) as email
    from app_private.child_payment_members member
    join app_private.registration_children registration_child on registration_child.id = member.registration_child_id
    join app_private.registrations registration on registration.id = registration_child.registration_id
    join app_private.household_members household_member on household_member.household_id = registration.household_id and household_member.revoked_at is null
    join auth.users user_account on user_account.id = household_member.user_id and user_account.email is not null
    where member.batch_id = batch.id
      and (_type <> 'payment_link_ready' or registration_child.child_id = batch.anchor_child_id)
  loop
    insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
    values (
      'child-payment:' || batch.id || ':' || batch.version || ':' || _type || ':' || recipient.id,
      _type,
      recipient.id::text,
      recipient.email,
      jsonb_build_object(
        'childBatchId', batch.id,
        'childBatchVersion', batch.version,
        'amountCents', batch.total_amount_cents,
        'externalUrl', case when _type = 'payment_link_ready' then batch.external_url end,
        'registrationReference', registration_reference,
        'paymentChildren', batch_payload->'childNames',
        'paymentChildDetails', child_details,
        'anchorChildName', batch_payload->>'anchorChildName',
        'actionPath', '/omgeving/meeloper/nachtpas'
      )
    )
    on conflict (dedupe_key) do nothing;
  end loop;
end;
$$;

revoke all on function app_private.enqueue_child_payment_email(uuid, text) from public, anon, authenticated;
