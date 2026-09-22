begin;
create extension if not exists pgtap with schema extensions;
select plan(32);

create temporary table registration_change_values(
  remove_registration uuid,
  remove_child uuid,
  cancellation_registration uuid,
  correction_registration uuid,
  remove_case uuid,
  cancellation_case uuid,
  correction_case uuid
) on commit drop;
insert into registration_change_values(remove_registration, remove_child, cancellation_registration, correction_registration)
select
  (select id from app_private.registrations where reference = 'FIXTURE-5'),
  (select child.id from app_private.registration_children child join app_private.registrations registration on registration.id = child.registration_id where registration.reference = 'FIXTURE-5' order by child.id limit 1),
  (select id from app_private.registrations where reference = 'FIXTURE-7'),
  (select id from app_private.registrations where reference = 'FIXTURE-10');
grant select, update on registration_change_values to authenticated;

update app_private.events
set change_deadline = now() - interval '1 minute'
where slug = 'duindorp-halloween-2026';

insert into app_private.payment_entries(request_id, amount_cents, entry_type, checked_by, checked_at, external_reference, reason)
select payment.id, payment.amount_cents, 'payment', 'f0000000-0000-0000-0000-000000000001', now(), 'fixture-paid', 'Betaald vóór wijzigingsverzoek'
from app_private.payment_requests payment
join app_private.registrations registration on registration.id = payment.registration_id
where registration.reference in ('FIXTURE-5', 'FIXTURE-7');

insert into app_private.together_parties(id, event_id, public_label, creator_household_id, invite_token_hash, expires_at)
select '42000000-0000-0000-0000-000000000001', registration.event_id, 'Te annuleren samenloop', registration.household_id,
       extensions.digest(convert_to('registration-change-fixture', 'utf8'), 'sha256'), now() + interval '1 day'
from app_private.registrations registration where registration.reference = 'FIXTURE-7';
insert into app_private.together_memberships(party_id, registration_id)
select '42000000-0000-0000-0000-000000000001', id from app_private.registrations where reference = 'FIXTURE-7';

select ok(not has_function_privilege('anon', 'api.registration_request_change(uuid,text,text,uuid)', 'execute'), 'anonymous visitors cannot submit registration changes');
select ok(not has_function_privilege('anon', 'api.admin_registration_changes_snapshot(text)', 'execute'), 'anonymous visitors cannot inspect registration requests');
select ok(not has_function_privilege('anon', 'api.admin_decide_registration_change(uuid,integer,text,text)', 'execute'), 'anonymous visitors cannot decide registration requests');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.registration_request_change((select remove_registration from registration_change_values), 'cancellation', 'Poging voor een ander huishouden', null) $$,
  '42501', 'NOT_AUTHORIZED', 'a different household cannot request a registration change'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
select lives_ok(
  $$ update registration_change_values set remove_case = (
    select (api.registration_request_change(
      remove_registration,
      'remove_child',
      'Dit kind kan helaas niet meer meelopen.',
      remove_child
    ) ->> 'id')::uuid
    from registration_change_values
  ) $$,
  'the owning household can request a child removal after the deadline'
);
set local role postgres;
select ok((select (request_payload ->> 'requestedAfterDeadline')::boolean from app_private.support_cases where id = (select remove_case from registration_change_values)), 'the request records that the change deadline has passed');
select is((select count(*)::integer from app_private.registration_children child join app_private.registrations registration on registration.id = child.registration_id where registration.reference = 'FIXTURE-5' and child.participation_status = 'active'), 5, 'requesting a change does not silently alter the registration');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_registration_changes_snapshot('duindorp-halloween-2026') $$,
  '42501', 'NOT_AUTHORIZED', 'an ordinary parent cannot inspect the private review queue'
);
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  (select item ->> 'kind' from jsonb_array_elements(api.admin_registration_changes_snapshot('duindorp-halloween-2026')) item where item ->> 'id' = (select remove_case::text from registration_change_values)),
  'remove_child',
  'registration management sees the structured child-removal request'
);
select lives_ok(
  $$ select api.admin_decide_registration_change((select remove_case from registration_change_values), 1, 'apply', 'Gecontroleerd met het huishouden en financieel beoordeeld') $$,
  'an authorized reviewer can apply the child removal'
);
set local role postgres;
select is((select count(*)::integer from app_private.registration_children child join app_private.registrations registration on registration.id = child.registration_id where registration.reference = 'FIXTURE-5' and child.participation_status = 'active'), 4, 'exactly one requested child is removed');
select is((select price_snapshot_cents from app_private.registrations where reference = 'FIXTURE-5'), 800, 'the authoritative registration total is recalculated');
select is((select totals_before ->> 'amountCents' from app_private.registration_revisions revision join app_private.registrations registration on registration.id = revision.registration_id where registration.reference = 'FIXTURE-5'), '1000', 'the revision preserves the amount before the change');
select is((select totals_after ->> 'amountCents' from app_private.registration_revisions revision join app_private.registrations registration on registration.id = revision.registration_id where registration.reference = 'FIXTURE-5'), '800', 'the revision records the corrected amount');
select is((select amount_cents from app_private.payment_requests payment join app_private.registrations registration on registration.id = payment.registration_id where registration.reference = 'FIXTURE-5'), 800, 'the payment request receives the corrected expected amount');
select is((select payment.status::text from app_private.payment_requests payment join app_private.registrations registration on registration.id = payment.registration_id where registration.reference = 'FIXTURE-5'), 'refund_due', 'an overpayment becomes an explicit refund task');
select is((select sum(entry.amount_cents)::integer from app_private.payment_entries entry join app_private.payment_requests payment on payment.id = entry.request_id join app_private.registrations registration on registration.id = payment.registration_id where registration.reference = 'FIXTURE-5'), 1000, 'the historical payment ledger is not rewritten');
select is((select status from app_private.support_cases where id = (select remove_case from registration_change_values)), 'resolved', 'the applied request is resolved');
select ok(exists (select 1 from app_private.audit_events where action = 'registration.change_applied' and resource_id = (select id from app_private.registrations where reference = 'FIXTURE-5')), 'the applied change is audited');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000007","role":"authenticated"}', true);
select lives_ok(
  $$ update registration_change_values set cancellation_case = (
    select (api.registration_request_change(cancellation_registration, 'cancellation', 'Ons huishouden annuleert de volledige deelname.', null) ->> 'id')::uuid
    from registration_change_values
  ) $$,
  'a household can request full cancellation'
);
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.admin_decide_registration_change((select cancellation_case from registration_change_values), 1, 'apply', 'Annulering gecontroleerd en terugbetaling als taak vastgelegd') $$,
  'registration and payment management can apply full cancellation'
);
set local role postgres;
select is((select status::text from app_private.registrations where reference = 'FIXTURE-7'), 'cancelled', 'the registration enters the cancelled state');
select is((select count(*)::integer from app_private.registration_children child join app_private.registrations registration on registration.id = child.registration_id where registration.reference = 'FIXTURE-7' and child.participation_status = 'active'), 0, 'cancelled registration children are no longer active');
select is((select amount_cents from app_private.payment_requests payment join app_private.registrations registration on registration.id = payment.registration_id where registration.reference = 'FIXTURE-7'), 0, 'a cancelled registration has no remaining amount due');
select is((select payment.status::text from app_private.payment_requests payment join app_private.registrations registration on registration.id = payment.registration_id where registration.reference = 'FIXTURE-7'), 'refund_due', 'a paid cancellation retains an explicit refund due status');
select ok((select superseded_at is not null from app_private.group_registrations assignment join app_private.registrations registration on registration.id = assignment.registration_id where registration.reference = 'FIXTURE-7'), 'cancellation removes the active group assignment without deleting history');
select ok((select left_at is not null from app_private.together_memberships membership join app_private.registrations registration on registration.id = membership.registration_id where registration.reference = 'FIXTURE-7'), 'cancellation leaves the together party without deleting its history');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000010","role":"authenticated"}', true);
select lives_ok(
  $$ update registration_change_values set correction_case = (
    select (api.registration_request_change(correction_registration, 'correction', 'Controleer de naamspelling bij deze inschrijving.', null) ->> 'id')::uuid
    from registration_change_values
  ) $$,
  'a general correction becomes a review request instead of a silent edit'
);
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.admin_decide_registration_change((select correction_case from registration_change_values), 1, 'close', 'Naamspelling gecontroleerd en handmatig afgehandeld') $$,
  'a reviewer can close a manually completed correction with a reason'
);
set local role postgres;
select is((select status from app_private.support_cases where id = (select correction_case from registration_change_values)), 'resolved', 'the correction retains an explicit resolved workflow state');
select is((select status::text from app_private.registrations where reference = 'FIXTURE-10'), 'submitted', 'closing a correction does not silently cancel the registration');
select ok(exists (select 1 from app_private.audit_events where action = 'registration.correction_resolved' and resource_id = (select correction_case from registration_change_values)), 'manual correction resolution is audited');

select * from finish();
rollback;
