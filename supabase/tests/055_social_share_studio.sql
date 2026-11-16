begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(not has_table_privilege('anon','app_private.social_share_templates','select'),'templates are not directly exposed');
select ok(not has_table_privilege('authenticated','app_private.social_share_generations','select'),'generated assets stay private');
select ok(not has_table_privilege('authenticated','app_private.social_share_pages','select'),'share pages use a narrow projection');
select ok(not has_table_privilege('authenticated','app_private.social_share_events','select'),'analytics contain no browser-readable actor history');
select ok(not has_function_privilege('anon','api.social_share_generation_reserve(text,uuid,uuid,text,text,text)','execute'),'anonymous browsers cannot call privileged generation reservation');
select ok(not has_function_privilege('authenticated','api.social_share_generation_reserve(text,uuid,uuid,text,text,text)','execute'),'authenticated browsers cannot choose another actor');
select ok(not has_function_privilege('authenticated','api.worker_social_share_cleanup_candidates(integer)','execute'),'retention cleanup remains worker-only');
select ok(has_function_privilege('anon','api.social_share_context(text)','execute'),'safe public catalog is available anonymously');
select ok(has_function_privilege('anon','api.social_share_public_page(text)','execute'),'safe public page projection is available anonymously');

-- This is a pre-event share catalog fixture. Move only its rollback-local
-- event/template dates relative to the real clock; production 2026 stays intact.
update app_private.events set local_date=(clock_timestamp() at time zone timezone)::date+30 where slug='duindorp-halloween-2026';
update app_private.social_share_templates t set valid_from=(e.local_date-90)::timestamp at time zone e.timezone,valid_until=(e.local_date+1)::timestamp at time zone e.timezone
from app_private.events e where t.event_id=e.id and e.slug='duindorp-halloween-2026' and t.template_key='countdown';
select set_config('request.jwt.claims','{"role":"anon"}',true);
select is(jsonb_array_length(api.social_share_context('duindorp-halloween-2026')->'cards'),3,'anonymous visitors receive only general, recruitment and countdown cards');
update app_private.social_share_templates set valid_until=now()-interval '1 second' where template_key='countdown' and event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
select is(jsonb_array_length(api.social_share_context('duindorp-halloween-2026')->'cards'),2,'expired countdown is correctly excluded using the real server clock');
update app_private.social_share_templates t set valid_until=(e.local_date+1)::timestamp at time zone e.timezone from app_private.events e where t.event_id=e.id and e.slug='duindorp-halloween-2026' and t.template_key='countdown';
select ok((api.social_share_context('duindorp-halloween-2026')->'cards')::text !~* 'child|email|phone|address|start(point|time|slot)|together.*code','public catalog has no sensitive projection keys');

select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select ok(exists(select 1 from jsonb_array_elements(api.social_share_context('duindorp-halloween-2026')->'cards') card where card->>'key'='participant'),'submitted participant receives their own card');
select ok((api.social_share_context('duindorp-halloween-2026')->'cards')::text !~* 'firstName|email|phone|address|startPoint|startTime|togetherCode|invite','participant projection contains no names, contacts, locations or codes');

select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select ok(exists(select 1 from jsonb_array_elements(api.social_share_context('duindorp-halloween-2026')->'cards') card where card->>'key'='gate_owner'),'owner receives a card for their own application');
select ok((api.social_share_context('duindorp-halloween-2026')->'cards')::text !~* 'NIET-BESTAAND|0612345678|owner@example','private fixture address and contact data never reach the share context');
select throws_ok($$select api.admin_social_share_publish('duindorp-halloween-2026','general_event',true,array['public'],array['story'],'/images/social-share/general/general-event-portrait.webp','/images/social-share/general/general-event-landscape.webp','{"publicEventPath":"/","houseRegistrationPath":"/huis-aanmelden"}',repeat('x',20),null,null,null,null)$$,'42501','NOT_AUTHORIZED','a poorteigenaar cannot publish templates');

select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_social_share_publish('duindorp-halloween-2026','general_event',true,array['public'],array['story','feed','square','landscape','opengraph'],'/images/social-share/general/general-event-portrait.webp','/images/social-share/general/general-event-landscape.webp','{"eyebrow":"HALLOWEEN AVONDLOOP","title":"DE DUINDORPSE POORTEN VAN HALLOWEEN","date":"31 OKTOBER 2026","publicDescription":"De Halloween-avondtocht door Duindorp.","publicEventPath":"/","houseRegistrationPath":"/huis-aanmelden"}','De Duindorpse Poorten komen eraan. Meer informatie: {{public_event_url}}',null,null,null,'deelstudio-test')$$,'event admin publishes an immutable new template version');
select is((select max(version) from app_private.social_share_templates where template_key='general_event'),2,'publishing creates a new version');
select is((select count(*)::integer from app_private.social_share_templates where template_key='general_event' and status='live'),1,'exactly one template version remains live');
select throws_ok($$select api.admin_social_share_publish('duindorp-halloween-2026','general_event',true,array['public'],array['story'],'/images/social-share/../../privacy.webp','/images/social-share/general/general-event-landscape.webp','{"publicEventPath":"/","houseRegistrationPath":"/huis-aanmelden"}',repeat('x',20),null,null,null,null)$$,'P0001','INVALID_INPUT','admin cannot publish a traversing asset path');
select throws_ok($$select api.admin_social_share_publish('duindorp-halloween-2026','general_event',true,array['public'],array['story'],'/images/social-share/general/general-event-portrait.webp','/images/social-share/general/general-event-landscape.webp','{"publicEventPath":"/","houseRegistrationPath":"/huis-aanmelden"}','Mail iemand via geheim@example.invalid om 18:30.',null,null,null,null)$$,'P0001','INVALID_INPUT','server rejects contact details and exact times in edited captions');

select is((select count(*)::integer from app_private.social_share_templates),12,'eleven seeded versions plus the tested immutable publication exist');
select ok(not exists(select 1 from app_private.social_share_templates where lower(default_caption) ~ 'laatste poort|eindpoort'),'captions never mention a final gate');
select ok(not exists(select 1 from app_private.social_share_templates template cross join app_private.registrations registration where template.template_key='join_us' and position(registration.together_code in template.default_caption)>0),'join caption contains no generated together code');
select ok(not exists(select 1 from app_private.social_share_templates where text_config::text ~* 'address|email|phone|child|startpoint|starttime'),'image configurations contain no sensitive fields');

select set_config('request.jwt.claims','{"role":"anon"}',true);
select lives_ok($$select api.social_share_track('duindorp-halloween-2026',null,'general_event','native_share_opened','native',gen_random_uuid())$$,'native share menu opening is recorded as its own honest event');
select is((select count(*)::integer from app_private.social_share_events where event_type='native_share_opened'),1,'analytics event is stored once without claiming success');

select * from finish();
rollback;
