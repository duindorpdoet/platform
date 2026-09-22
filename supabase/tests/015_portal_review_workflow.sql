begin;
create extension if not exists pgtap with schema extensions;
select plan(29);

insert into app_private.portal_applications(
  id, event_id, applicant_user_id, review_status, private_draft_data, submitted_at
)
select
  '11000000-0000-0000-0000-000000000900',
  event.id,
  'b0000000-0000-0000-0000-000000000001',
  'submitted',
  jsonb_build_object(
    'contactName', 'Testbewoner',
    'phone', '0612345678',
    'address', jsonb_build_object('street', 'NIET-BESTAAND REVIEWPAD', 'houseNumber', '9', 'addition', 'A', 'postalCode', '2584 AB'),
    'entrance', 'Zelfde ingang als het testadres',
    'requestedWorldSlug', 'heksenrijk',
    'portalName', 'De Reviewpoort',
    'description', 'Een uitsluitend fictieve poort voor de geautomatiseerde beoordelingstest.',
    'intensity', '3',
    'warnings', jsonb_build_object('smoke', true, 'flashes', false, 'sound', false, 'actors', true, 'allergens', false),
    'availableFrom', '18:15',
    'availableUntil', '21:45',
    'visitMinutes', '6',
    'maxConcurrentGroups', '2',
    'maxChildrenPerVisit', '14',
    'maxChildrenTotal', '140',
    'accessibility', 'mixed',
    'availability', true,
    'locationConsent', true
  ),
  now()
from app_private.events event where event.slug = 'duindorp-halloween-2026';

select ok(not has_function_privilege('anon', 'api.admin_portal_applications_snapshot(text)', 'execute'), 'application review snapshot is not public');
select ok(not has_function_privilege('anon', 'api.admin_review_portal_application(uuid,integer,text,text,numeric,numeric,text)', 'execute'), 'review command is not public');
select ok(not has_function_privilege('anon', 'api.admin_verify_portal_location(uuid,integer,numeric,numeric,text)', 'execute'), 'location verification is not public');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select lives_ok(
  $$ select api.portal_application_save('duindorp-halloween-2026', '{"address":{"street":"Conceptstraat"}}'::jsonb, null) $$,
  'an incomplete private house draft can be saved before submission'
);
select is(api.portal_snapshot('duindorp-halloween-2026') #>> '{application,draft,address,street}', 'Conceptstraat', 'the incomplete draft survives a fresh snapshot');
select throws_ok(
  $$ select api.portal_application_submit(
    (api.portal_snapshot('duindorp-halloween-2026') #>> '{application,id}')::uuid,
    (api.portal_snapshot('duindorp-halloween-2026') #>> '{application,version}')::integer,
    'incomplete-portal-submit', 'incomplete-portal-submit-hash'
  ) $$,
  '22023', 'VALIDATION_ERROR', 'an incomplete house draft cannot be submitted'
);

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.portal_snapshot('duindorp-halloween-2026') #>> '{application,draft,portalName}',
  'De Reviewpoort',
  'the applicant can restore the private submitted draft after a refresh'
);
select throws_ok(
  $$ select api.admin_portal_applications_snapshot('duindorp-halloween-2026') $$,
  '42501', 'NOT_AUTHORIZED', 'an ordinary applicant cannot enumerate private applications'
);
select throws_ok(
  $$ select api.admin_review_portal_application('11000000-0000-0000-0000-000000000900', 1, 'approved', 'heksenrijk', null, null, 'Gewone gebruiker mag dit niet') $$,
  '42501', 'NOT_AUTHORIZED', 'an ordinary applicant cannot approve their own application'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.admin_portal_applications_snapshot('duindorp-halloween-2026') -> 'applications' -> 0 ->> 'applicantEmail',
  'parent-b@example.invalid',
  'an authorized reviewer sees the applicant identity in the private review queue'
);
select lives_ok(
  $$ select api.admin_review_portal_application('11000000-0000-0000-0000-000000000900', 1, 'changes_requested', null, null, null, 'Licht de toegankelijke ingang duidelijker toe') $$,
  'an authorized reviewer can request a versioned change'
);

select set_config('request.jwt.claims', '{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.portal_snapshot('duindorp-halloween-2026') #>> '{application,reviewFeedback}',
  'Licht de toegankelijke ingang duidelijker toe',
  'the applicant receives private review feedback'
);
select lives_ok(
  $$ select api.portal_application_save(
    'duindorp-halloween-2026',
    api.portal_snapshot('duindorp-halloween-2026') #> '{application,draft}',
    2
  ) $$,
  'the applicant can save a requested revision'
);
select lives_ok(
  $$ select api.portal_application_submit(
    '11000000-0000-0000-0000-000000000900', 3,
    'portal-review-resubmit', 'portal-review-resubmit-hash'
  ) $$,
  'the complete revised application can be resubmitted'
);
select is(api.portal_snapshot('duindorp-halloween-2026') #>> '{application,status}', 'submitted', 'resubmission clears the editable review state');

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.admin_review_portal_application('11000000-0000-0000-0000-000000000900', 4, 'approved', 'heksenrijk', null, null, 'Volledig beoordeeld en inhoudelijk akkoord') $$,
  'an authorized reviewer can approve a complete application without pretending the address is verified'
);

set local role postgres;
select is((select review_status::text from app_private.portal_applications where id = '11000000-0000-0000-0000-000000000900'), 'approved', 'approval changes the application state');
select is((select count(*)::integer from app_private.portals where application_id = '11000000-0000-0000-0000-000000000900'), 1, 'approval creates exactly one portal');
select is((select count(*)::integer from app_private.portal_owners owner join app_private.portals portal on portal.id = owner.portal_id where portal.application_id = '11000000-0000-0000-0000-000000000900' and owner.revoked_at is null), 1, 'approval assigns exactly one active owner');
select is((select count(*)::integer from app_private.portal_publications publication join app_private.portals portal on portal.id = publication.portal_id where portal.application_id = '11000000-0000-0000-0000-000000000900'), 1, 'approval creates a privacy-safe publication');
select is((select count(*)::integer from app_private.portal_windows window_record join app_private.portals portal on portal.id = window_record.portal_id where portal.application_id = '11000000-0000-0000-0000-000000000900'), 1, 'approval creates one operating window');
select is((select to_char(window_record.opens_at at time zone 'Europe/Amsterdam', 'HH24:MI') from app_private.portal_windows window_record join app_private.portals portal on portal.id = window_record.portal_id where portal.application_id = '11000000-0000-0000-0000-000000000900'), '18:15', 'the applicant opening time uses the event timezone');
select is((select location.verified_at from app_private.portal_private_locations location join app_private.portals portal on portal.id = location.portal_id where portal.application_id = '11000000-0000-0000-0000-000000000900'), null::timestamptz, 'approval alone does not verify a physical location');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  jsonb_array_length((select api.admin_planning_snapshot('duindorp-halloween-2026') -> 'portals')),
  30,
  'an unverified newly approved portal is absent from planning input'
);
select throws_ok(
  $$ select api.admin_review_portal_application('11000000-0000-0000-0000-000000000900', 1, 'approved', 'heksenrijk', null, null, 'Tweede goedkeuring moet worden geweigerd') $$,
  '40001', 'STALE_VERSION', 'a stale duplicate approval is rejected before it can create another portal'
);
select lives_ok(
  $$ select api.admin_verify_portal_location(
    (api.admin_portal_applications_snapshot('duindorp-halloween-2026') #>> '{applications,0,portal,id}')::uuid,
    1, 52.105000, 4.275000, 'Adres op locatie fysiek gecontroleerd'
  ) $$,
  'an authorized reviewer can explicitly verify the physical location'
);
select is(
  jsonb_array_length((select api.admin_planning_snapshot('duindorp-halloween-2026') -> 'portals')),
  31,
  'only after location verification is the portal available to the planner'
);

set local role postgres;
select is((select version from app_private.portals where application_id = '11000000-0000-0000-0000-000000000900'), 2, 'location verification advances the portal version');
select is((select count(*)::integer from app_private.audit_events where resource_id in ('11000000-0000-0000-0000-000000000900', (select id from app_private.portals where application_id = '11000000-0000-0000-0000-000000000900')) and action in ('portal_application.approved', 'portal.location_verified')), 2, 'approval and verification both leave an audit trail');

select * from finish();
rollback;
