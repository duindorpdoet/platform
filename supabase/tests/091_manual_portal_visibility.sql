begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table manual_visibility(pid uuid,inv uuid,mail uuid,result jsonb,original_final uuid);
grant select,update on manual_visibility to authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into manual_visibility(original_final,result) select final_portal_id,api.admin_manual_portal_save('duindorp-halloween-2026',null,
  '{"name":"Zichtbare concept-eindpoort","worldSlug":"anders","contactEmail":"parent-size-5@example.invalid","lifecycleStatus":"concept","approvalStatus":"draft","isFinal":true,"confirmFinal":true,"commandKey":"visible-manual-concept-01"}',null,
  'Concept-eindpoort zichtbaar in het echte organisatieoverzicht') from app_private.event_route_settings where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
update manual_visibility set pid=(result->>'id')::uuid,inv=(result->'instructions'->>'inviteId')::uuid,mail=(result->'instructions'->>'outboxId')::uuid;
update app_private.email_outbox set status='unknown',last_error_code='WORKER_LEASE_EXPIRED_AFTER_CLAIM' where id=(select mail from manual_visibility);

select ok(exists(select 1 from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026')->'conceptPortals') p
  where p->>'id'=(select pid::text from manual_visibility)), 'manual concepts appear without a resident intake or application');
select ok(exists(select 1 from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026')->'conceptPortals') p
  where p->>'id'=(select pid::text from manual_visibility) and p->>'isFinal'='true'), 'the designated final portal keeps its final-portal identity while still a concept');
select is((select count(*) from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026')->'conceptPortals') p
  where p->>'id'=(select pid::text from manual_visibility)),1::bigint,'the concept is counted exactly once');
select ok(exists(select 1 from jsonb_array_elements(api.admin_portal_records_snapshot('duindorp-halloween-2026')->'portals') p
  where p->>'id'=(select pid::text from manual_visibility) and p->>'instructionStatus'='unknown'), 'the editor exposes the actual unknown instruction-mail status');
select is((select count(*) from app_private.portal_owners where portal_id=(select pid from manual_visibility)),0::bigint,'visibility grants no membership before invitation acceptance');
select is((select approval_status::text from app_private.portals where id=(select pid from manual_visibility)),'draft','visibility does not approve or activate the concept');
select ok(not has_function_privilege('anon','api.admin_portal_management_snapshot(text)','execute'),'anonymous callers cannot inspect organization concepts');
select ok(not has_function_privilege('authenticated','api.admin_portal_management_snapshot_before_manual_concepts(text)','execute'),'the internal projection remains inaccessible directly');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select throws_ok($$select api.admin_portal_management_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','an ordinary participant cannot inspect organization concepts');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_portal_management_snapshot('duindorp-halloween-2026')$$,'authorized organization can inspect the concept');
reset role;
update app_private.portals set lifecycle_status='registered' where id=(select pid from manual_visibility);
select ok(exists(select 1 from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026')->'conceptPortals') p
  where p->>'id'=(select pid::text from manual_visibility)), 'a registered manual concept remains visible before approval');
update app_private.portals set lifecycle_status='approved',approval_status='approved' where id=(select pid from manual_visibility);
select ok(not exists(select 1 from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026')->'conceptPortals') p
  where p->>'id'=(select pid::text from manual_visibility)), 'approved records no longer inflate the concept counter');
update app_private.portals set lifecycle_status='archived',approval_status='withdrawn' where id=(select pid from manual_visibility);
select ok(not exists(select 1 from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026')->'conceptPortals') p
  where p->>'id'=(select pid::text from manual_visibility)), 'archived records stay out of the concept list');
select * from finish();
rollback;
