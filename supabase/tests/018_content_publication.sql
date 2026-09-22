begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into app_private.sponsor_applications(id, event_id, contact_name, contact_email, contribution_type, proposed_amount_cents, message, review_status)
select '41000000-0000-0000-0000-000000000001', event.id, 'Privé contactnaam', 'private-sponsor@example.invalid', 'geld', 2500, 'Privé voorstel dat nooit publiek mag worden.', 'submitted'
from app_private.events event where event.slug = 'duindorp-halloween-2026';

create temporary table content_values(id uuid, version integer) on commit drop;
grant select on content_values to authenticated;

set local role anon;
select is(api.event_public_snapshot('duindorp-halloween-2026')->'content', '{}'::jsonb, 'public content starts empty without an approved publication');
select is(jsonb_array_length(api.event_public_snapshot('duindorp-halloween-2026')->'sponsors'), 0, 'an unreviewed sponsor application is not public');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_content_snapshot('duindorp-halloween-2026') $$,
  '42501', 'NOT_AUTHORIZED', 'an ordinary parent cannot read private content and sponsor review data'
);
select throws_ok(
  $$ select api.admin_save_content_draft('duindorp-halloween-2026', 'home', 'nl-NL', '{"title":"Onbevoegd","body":"Niet publiceren"}'::jsonb) $$,
  '42501', 'NOT_AUTHORIZED', 'an ordinary parent cannot create a content version'
);

select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.admin_save_content_draft('duindorp-halloween-2026', 'home', 'nl-NL', '{"title":"Eerste versie","body":"Alleen na goedkeuring zichtbaar."}'::jsonb) $$,
  'a content manager can save a new immutable draft version'
);
set local role postgres;
insert into content_values select id, version from app_private.content_versions where page_key = 'home' and version = 1;
set local role anon;
select ok(not (api.event_public_snapshot('duindorp-halloween-2026')->'content' ? 'home'), 'a saved draft remains absent from the public projection');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.admin_publish_content((select id from content_values where version = 1), 1, 'Eerste contentversie gecontroleerd en akkoord') $$,
  'a content manager explicitly publishes the reviewed draft'
);
set local role anon;
select is(api.event_public_snapshot('duindorp-halloween-2026') #>> '{content,home,title}', 'Eerste versie', 'only the published content version appears publicly');
set local role postgres;
select ok(exists (select 1 from app_private.audit_events where action = 'content.published' and resource_id = (select id from content_values where version = 1)), 'content publication is audited');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.admin_save_content_draft('duindorp-halloween-2026', 'home', 'nl-NL', '{"title":"Tweede versie","body":"Een gecontroleerde vervanging."}'::jsonb) $$,
  'a later edit creates another draft instead of mutating the publication'
);
set local role postgres;
insert into content_values select id, version from app_private.content_versions where page_key = 'home' and version = 2;
set local role anon;
select is(api.event_public_snapshot('duindorp-halloween-2026') #>> '{content,home,title}', 'Eerste versie', 'the first publication remains public while revision two is a draft');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.admin_publish_content((select id from content_values where version = 2), 2, 'Tweede contentversie gecontroleerd en akkoord') $$,
  'the replacement requires its own explicit publication'
);
set local role postgres;
select is((select status from app_private.content_versions where page_key = 'home' and version = 1), 'archived', 'publishing a replacement archives the previous public version');
select is((select count(*)::integer from app_private.content_versions where page_key = 'home' and status = 'published'), 1, 'the database permits exactly one published version per page and locale');
set local role anon;
select is(api.event_public_snapshot('duindorp-halloween-2026') #>> '{content,home,title}', 'Tweede versie', 'the public projection switches atomically to the approved replacement');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$ select api.admin_publish_sponsor('41000000-0000-0000-0000-000000000001', 1, 'Onbevoegd', '', 0, 'Onbevoegde sponsorpublicatie') $$,
  '42501', 'NOT_AUTHORIZED', 'an ordinary parent cannot approve a sponsor'
);
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select api.admin_publish_sponsor('41000000-0000-0000-0000-000000000001', 1, 'Goedgekeurde Testsponsor', 'https://sponsor.example.invalid/', 10, 'Sponsorinhoud gecontroleerd en akkoord') $$,
  'a content manager can publish only explicitly approved sponsor fields'
);
set local role anon;
select is(api.event_public_snapshot('duindorp-halloween-2026') #>> '{sponsors,0,name}', 'Goedgekeurde Testsponsor', 'the approved sponsor name appears publicly');
select ok(api.event_public_snapshot('duindorp-halloween-2026')::text not like '%private-sponsor@example.invalid%' and api.event_public_snapshot('duindorp-halloween-2026')::text not like '%Privé voorstel%', 'private sponsor contact details and message never enter the public projection');
set local role postgres;
select ok(exists (select 1 from app_private.audit_events where action = 'sponsor.published' and resource_id = '41000000-0000-0000-0000-000000000001'), 'sponsor publication is audited');

select * from finish();
rollback;
