begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

insert into app_private.portal_applications(
  id, event_id, applicant_user_id, review_status, private_draft_data, submitted_at
)
select
  '11000000-0000-0000-0000-000000000940',
  event.id,
  'b0000000-0000-0000-0000-000000000001',
  'submitted',
  jsonb_build_object(
    'contactName', 'Bewoner Minimum',
    'phone', '0612345678',
    'address', jsonb_build_object(
      'street', 'Minimumpad',
      'houseNumber', '12',
      'postalCode', '2583 PS'
    ),
    'availability', false,
    'locationConsent', false
  ),
  now()
from app_private.events event
where event.slug = 'duindorp-halloween-2026';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);

select lives_ok(
  $$ select api.admin_review_portal_application(
    '11000000-0000-0000-0000-000000000940', 1, 'approved', null,
    null, null, 'Contact en adres zijn gecontroleerd'
  ) $$,
  'the organisation can approve with only contact details and a complete address'
);

set local role postgres;
select is(
  (select review_status::text from app_private.portal_applications where id = '11000000-0000-0000-0000-000000000940'),
  'approved',
  'the minimum application is approved'
);
select is(
  (select private_draft_data ->> 'portalName' from app_private.portal_applications where id = '11000000-0000-0000-0000-000000000940'),
  'Snoeppunt van Bewoner Minimum',
  'a safe display name is supplied'
);
select is(
  (select private_draft_data ->> 'availableFrom' from app_private.portal_applications where id = '11000000-0000-0000-0000-000000000940'),
  '17:00',
  'the default opening time is 17:00'
);
select is(
  (select private_draft_data ->> 'availableUntil' from app_private.portal_applications where id = '11000000-0000-0000-0000-000000000940'),
  '21:00',
  'the default closing time is 21:00'
);
select is(
  (select private_draft_data #>> '{address,postalCode}' from app_private.portal_applications where id = '11000000-0000-0000-0000-000000000940'),
  '2583PS',
  'the postcode is normalized'
);
select is(
  (select count(*)::integer from app_private.portals where application_id = '11000000-0000-0000-0000-000000000940'),
  1,
  'approval creates the house portal'
);
select is(
  (select world.slug from app_private.portals portal join app_private.worlds world on world.id = portal.world_id where portal.application_id = '11000000-0000-0000-0000-000000000940'),
  'anders',
  'a missing category uses the sweets-only category'
);
select is(
  (select to_char(window_record.opens_at at time zone 'Europe/Amsterdam', 'HH24:MI') from app_private.portal_windows window_record join app_private.portals portal on portal.id = window_record.portal_id where portal.application_id = '11000000-0000-0000-0000-000000000940'),
  '17:00',
  'the portal window starts at the safe default'
);
select is(
  (select to_char(window_record.closes_at at time zone 'Europe/Amsterdam', 'HH24:MI') from app_private.portal_windows window_record join app_private.portals portal on portal.id = window_record.portal_id where portal.application_id = '11000000-0000-0000-0000-000000000940'),
  '21:00',
  'the portal window ends at the safe default'
);
select is(
  (select location.street from app_private.portal_private_locations location join app_private.portals portal on portal.id = location.portal_id where portal.application_id = '11000000-0000-0000-0000-000000000940'),
  'Minimumpad',
  'the supplied address is retained privately'
);
select is(
  (select location.verified_at from app_private.portal_private_locations location join app_private.portals portal on portal.id = location.portal_id where portal.application_id = '11000000-0000-0000-0000-000000000940'),
  null::timestamptz,
  'approval does not pretend the address is physically verified'
);

insert into app_private.portal_applications(
  id, event_id, applicant_user_id, review_status, private_draft_data, submitted_at
)
select
  '11000000-0000-0000-0000-000000000941',
  event.id,
  'b0000000-0000-0000-0000-000000000001',
  'submitted',
  jsonb_build_object('contactName', 'Zonder adres', 'phone', '0612345678'),
  now()
from app_private.events event
where event.slug = 'duindorp-halloween-2026';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_review_portal_application(
    '11000000-0000-0000-0000-000000000941', 1, 'approved', 'anders',
    null, null, 'Adres ontbreekt nog volledig'
  ) $$,
  '23514', 'CONTACT_ADDRESS_REQUIRED',
  'approval still requires a complete address'
);

select * from finish();
rollback;
