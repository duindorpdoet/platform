-- Premium transactional mail is queued in the same transaction as the
-- underlying state change. Rendering and delivery remain the responsibility
-- of the existing email_outbox worker and SendGrid hook.

create or replace function app_private.enqueue_payment_state_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  registration app_private.registrations;
  recipient record;
  v_type text;
  v_revision text;
begin
  if new.registration_id is null then return new; end if;
  select * into registration from app_private.registrations where id = new.registration_id;
  if registration.id is null then return new; end if;

  if old.external_url is distinct from new.external_url and new.external_url is not null
     and new.status = 'awaiting_payment' then
    v_type := 'payment_link_ready';
  elsif old.status is distinct from new.status and new.status = 'reported' then
    v_type := 'payment_reported';
  elsif old.status is distinct from new.status and new.status = 'confirmed' then
    v_type := 'payment_confirmed';
  else
    return new;
  end if;
  v_revision := new.version::text;

  for recipient in
    select distinct users.id, lower(users.email) as email
    from app_private.household_members member
    join auth.users users on users.id = member.user_id and users.email is not null
    where member.household_id = registration.household_id and member.revoked_at is null
  loop
    insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
    values (
      'payment:' || new.id::text || ':' || v_type || ':' || v_revision || ':' || recipient.id::text,
      v_type, recipient.id::text, recipient.email,
      jsonb_build_object(
        'registrationReference', registration.reference,
        'amountCents', new.amount_cents,
        'paymentStatus', new.status,
        'externalUrl', case when v_type = 'payment_link_ready' then new.external_url else null end,
        'actionPath', '/mijn-inschrijving'
      )
    ) on conflict (dedupe_key) do nothing;
  end loop;
  return new;
end;
$$;

drop trigger if exists payment_requests_transactional_mail on app_private.payment_requests;
create trigger payment_requests_transactional_mail
after update of status, external_url on app_private.payment_requests
for each row execute function app_private.enqueue_payment_state_email();

create or replace function app_private.enqueue_portal_claim_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  application app_private.portal_applications;
  recipient_email text;
begin
  if old.claimed_at is not null or new.claimed_at is null or new.application_id is null or new.claimed_user_id is null then
    return new;
  end if;
  select * into application from app_private.portal_applications where id = new.application_id;
  select lower(email) into recipient_email from auth.users where id = new.claimed_user_id;
  if application.id is null or recipient_email is null then return new; end if;
  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values (
    'portal:' || application.id::text || ':registered:' || new.claimed_user_id::text,
    'portal_registered', new.claimed_user_id::text, recipient_email,
    jsonb_build_object(
      'applicationId', application.id,
      'contactName', application.private_draft_data ->> 'contactName',
      'actionPath', '/omgeving/huiseigenaar/mijn-poort'
    )
  ) on conflict (dedupe_key) do nothing;
  return new;
end;
$$;

drop trigger if exists portal_registration_claimed_mail on app_private.portal_registration_intakes;
create trigger portal_registration_claimed_mail
after update of claimed_at on app_private.portal_registration_intakes
for each row execute function app_private.enqueue_portal_claim_email();

create or replace function app_private.enqueue_portal_review_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  recipient_email text;
  v_type text;
  portal_record app_private.portals;
begin
  if old.review_status is not distinct from new.review_status then return new; end if;
  if new.review_status = 'approved' then v_type := 'portal_approved';
  elsif new.review_status = 'rejected' then v_type := 'portal_rejected';
  elsif new.review_status = 'changes_requested' and new.reviewed_by is not null then v_type := 'portal_changes_requested';
  else return new;
  end if;
  select lower(email) into recipient_email from auth.users where id = new.applicant_user_id;
  if recipient_email is null then return new; end if;
  select * into portal_record from app_private.portals where application_id = new.id;
  insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
  values (
    'portal:' || new.id::text || ':' || v_type || ':' || new.version::text || ':' || new.applicant_user_id::text,
    v_type, new.applicant_user_id::text, recipient_email,
    jsonb_build_object(
      'applicationId', new.id,
      'applicationVersion', new.version,
      'portalName', coalesce(portal_record.name, new.private_draft_data ->> 'portalName'),
      'reviewFeedback', new.review_feedback,
      'actionPath', '/omgeving/huiseigenaar/mijn-poort'
    )
  ) on conflict (dedupe_key) do nothing;
  return new;
end;
$$;

drop trigger if exists portal_applications_review_mail on app_private.portal_applications;
create trigger portal_applications_review_mail
after update of review_status on app_private.portal_applications
for each row execute function app_private.enqueue_portal_review_email();

create or replace function app_private.enqueue_together_request_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_party app_private.together_parties;
  target_registration app_private.registrations;
  recipient record;
  v_type text;
  v_group_name text;
  v_system_code text;
begin
  if tg_op = 'INSERT' then v_type := 'group_merge_requested';
  elsif old.status = 'pending' and new.status = 'accepted' then v_type := 'group_merge_approved';
  elsif old.status = 'pending' and new.status = 'rejected' then v_type := 'group_merge_declined';
  else return new;
  end if;

  select * into target_party
  from app_private.together_parties
  where id = new.target_party_id;
  if target_party.id is null then return new; end if;

  select registration.* into target_registration
  from app_private.registrations registration
  where registration.event_id = new.event_id
    and registration.household_id = target_party.creator_household_id
    and registration.status <> 'cancelled'
  order by registration.created_at, registration.id
  limit 1;

  select walking_group.display_name, walking_group.system_code
  into v_group_name, v_system_code
  from app_private.group_registrations assignment
  join app_private.walking_groups walking_group on walking_group.id = assignment.group_id
  where assignment.registration_id = target_registration.id
    and assignment.superseded_at is null
  order by assignment.assigned_at desc, assignment.id desc
  limit 1;
  v_group_name := coalesce(v_group_name, v_system_code, target_party.public_label, 'de hoofdgroep');

  for recipient in
    select distinct candidates.id, candidates.email
    from (
      -- A pending request is actionable only for the primary contact of the
      -- target (head) party. The requesting household must not receive the
      -- head-group template as though it could approve its own request.
      select users.id, lower(users.email) as email
      from app_private.households household
      join app_private.household_members member
        on member.household_id = household.id
       and member.user_id = household.primary_contact_user_id
       and member.revoked_at is null
      join auth.users users
        on users.id = member.user_id
       and users.email is not null
      where v_type = 'group_merge_requested'
        and household.id = target_party.creator_household_id

      union all

      -- Terminal decisions concern every registered adult who belonged to
      -- either party when the request was made. Looking at that timestamp
      -- also survives an accepted request moving the source memberships into
      -- the target party before this AFTER trigger runs.
      select users.id, lower(users.email) as email
      from app_private.together_memberships membership
      join app_private.registrations registration
        on registration.id = membership.registration_id
      join app_private.household_members member
        on member.household_id = registration.household_id
       and member.revoked_at is null
      join auth.users users
        on users.id = member.user_id
       and users.email is not null
      where v_type in ('group_merge_approved', 'group_merge_declined')
        and membership.party_id in (new.source_party_id, new.target_party_id)
        and membership.joined_at <= new.created_at
        and (membership.left_at is null or membership.left_at >= new.created_at)
    ) candidates
  loop
    insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
    values (
      'group-merge:' || new.id::text || ':' || v_type || ':' || recipient.id::text,
      v_type, recipient.id::text, recipient.email,
      jsonb_strip_nulls(jsonb_build_object(
        'requestId', new.id,
        'requestedCode', new.requested_code,
        'groupName', v_group_name,
        'headGroup', v_group_name,
        'groupCode', v_system_code,
        'systemCode', v_system_code,
        'actionPath', '/omgeving/meeloper/groep'
      ))
    ) on conflict (dedupe_key) do nothing;
  end loop;
  return new;
end;
$$;

drop trigger if exists together_requests_transactional_mail on app_private.together_join_requests;
create trigger together_requests_transactional_mail
after insert or update of status on app_private.together_join_requests
for each row execute function app_private.enqueue_together_request_email();

-- Receipt messages for public contact and sponsor submissions are deliberately
-- generated from the durable stored records, never from an untrusted recipient.
create or replace function app_private.enqueue_public_form_receipt()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_table_name = 'contact_messages' then
    insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
    values (
      'contact:' || new.id::text || ':received', 'contact_received', new.id::text, lower(new.sender_email),
      jsonb_build_object('ticketReference', new.id, 'contactName', new.sender_name, 'actionPath', '/contact')
    ) on conflict (dedupe_key) do nothing;
  elsif tg_table_name = 'sponsor_applications' then
    insert into app_private.email_outbox(dedupe_key, message_type, recipient_ref, recipient_email, payload)
    values (
      'sponsor:' || new.id::text || ':received', 'sponsor_received', new.id::text, lower(new.contact_email),
      jsonb_build_object('applicationReference', new.id, 'contactName', new.contact_name, 'actionPath', '/sponsoren')
    ) on conflict (dedupe_key) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists contact_messages_receipt_mail on app_private.contact_messages;
create trigger contact_messages_receipt_mail after insert on app_private.contact_messages
for each row execute function app_private.enqueue_public_form_receipt();
drop trigger if exists sponsor_applications_receipt_mail on app_private.sponsor_applications;
create trigger sponsor_applications_receipt_mail after insert on app_private.sponsor_applications
for each row execute function app_private.enqueue_public_form_receipt();

revoke execute on function app_private.enqueue_payment_state_email() from public, anon, authenticated;
revoke execute on function app_private.enqueue_portal_claim_email() from public, anon, authenticated;
revoke execute on function app_private.enqueue_portal_review_email() from public, anon, authenticated;
revoke execute on function app_private.enqueue_together_request_email() from public, anon, authenticated;
revoke execute on function app_private.enqueue_public_form_receipt() from public, anon, authenticated;
