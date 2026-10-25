begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table test_ops(eid uuid,impact jsonb,result jsonb,key text default gen_random_uuid()::text,group_id uuid,composition_hash text,plan_hash text);
insert into test_ops(eid) select id from app_private.events where slug='duindorp-halloween-2026';
create temp table preserved as select 'children' kind,md5(jsonb_agg(to_jsonb(c) order by c.id)::text) hash from app_private.registration_children c
 union all select 'payments',md5(jsonb_agg(to_jsonb(p) order by p.id)::text) from app_private.payment_requests p
 union all select 'together',md5(jsonb_agg(to_jsonb(m) order by m.party_id,m.registration_id)::text) from app_private.together_memberships m
 union all select 'publications',md5(jsonb_agg(to_jsonb(p) order by p.publication_order)::text) from app_private.group_start_publications p;
select ok(not has_function_privilege('anon','api.admin_group_operations_apply(text,text,text,jsonb,text)','execute'),'anonymous has no composition commands');
update test_ops set group_id='23000000-0000-0000-0000-000000000001';
update test_ops set composition_hash=app_private.start_group_composition_hash(group_id),plan_hash=app_private.start_planning_input_hash(eid);
-- Financial updates really mutate the finance records, but not structural planning hashes.
update app_private.payment_requests set status='awaiting_link',version=version+1 where registration_id in(select registration_id from app_private.group_registrations where group_id=(select group_id from test_ops) and superseded_at is null);
select is(app_private.start_group_composition_hash(group_id),composition_hash,'payment-only update preserves composition fingerprint') from test_ops;
select is(app_private.start_planning_input_hash(eid),plan_hash,'payment-only update preserves planning fingerprint') from test_ops;
update test_ops set impact=api.admin_group_operations_preview('duindorp-halloween-2026');
select lives_ok($$update test_ops set result=api.admin_group_operations_apply('duindorp-halloween-2026','confirm',impact->>'inputHash',jsonb_build_object('groupId',group_id),key)$$,'unpaid group can confirm composition');
select is(api.admin_group_operations_apply('duindorp-halloween-2026','confirm',impact->>'inputHash',jsonb_build_object('groupId',group_id),key),result,'exact confirmation retry returns original receipt') from test_ops;
select is((select composition_revision from app_private.walking_groups where id=(select group_id from test_ops)),1,'one composition revision');
select ok((select count(*) from app_private.email_outbox where message_type='group_composition_confirmed' and payload->>'groupId'=(select group_id::text from test_ops))>0,'composition confirmation enqueues personal adult notifications');
select throws_ok($$select api.admin_group_move_registration('duindorp-halloween-2026',(select registration_id from app_private.group_registrations where group_id=(select group_id from test_ops) and superseded_at is null limit 1),null)$$,'23514','GROUPS_FINALIZED','confirmed published composition remains protected');
update test_ops set impact=api.admin_group_operations_preview('duindorp-halloween-2026'),key=gen_random_uuid()::text;
select lives_ok($$update test_ops set result=api.admin_group_operations_apply('duindorp-halloween-2026','reset',impact->>'inputHash','{"confirmation":"ALLE GROEPEN TERUGZETTEN"}',key)$$,'one atomic reviewed reset');
select is(api.admin_group_operations_apply('duindorp-halloween-2026','reset',impact->>'inputHash','{"confirmation":"ALLE GROEPEN TERUGZETTEN"}',key),result,'reset replay is safe after data changed') from test_ops;
select is((select count(*)::integer from app_private.walking_groups where event_id=(select eid from test_ops) and retired_at is null),0,'no active groups after reset');
select is(jsonb_array_length(api.admin_group_composition_snapshot('duindorp-halloween-2026')->'groups'),0,'retired groups absent from kanban');
select is(jsonb_array_length(api.admin_startregie_snapshot('duindorp-halloween-2026')->'groups'),0,'retired groups absent from start planning');
select is((select count(*)::integer from app_private.group_registrations where superseded_at is null),0,'all current memberships ended');
select is((select md5(jsonb_agg(to_jsonb(p) order by p.publication_order)::text) from app_private.group_start_publications p),(select hash from preserved where kind='publications'),'immutable publications retained');
select is((select count(*)::integer from app_private.walking_groups where app_private.published_start_projection(id) is not null),0,'withdrawn participant instructions are not valid');
select is((select count(*)::integer from app_private.email_outbox where message_type in ('group_schedule_published','group_schedule_corrected','group_composition_confirmed') and status in ('pending','deferred')),0,'obsolete pending confirmations suppressed');
select is((select md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.registration_children c),(select hash from preserved where kind='children'),'children and child financial links retained');
select is((select md5(jsonb_agg(to_jsonb(m) order by m.party_id,m.registration_id)::text) from app_private.together_memberships m),(select hash from preserved where kind='together'),'true party identities retained');
-- Construct intact unassigned blocks through the actual server projection, without any slots.
update test_ops set impact=api.admin_group_operations_preview('duindorp-halloween-2026'),key=gen_random_uuid()::text;
select lives_ok($$select api.admin_group_operations_apply('duindorp-halloween-2026','autofill',(select impact->>'inputHash' from test_ops),jsonb_build_object('groups',(select jsonb_agg(jsonb_build_object('registrationIds',ids)) from(select jsonb_agg(r->'id') ids from jsonb_array_elements(api.admin_group_composition_snapshot('duindorp-halloween-2026')->'unassigned') r where (r->>'childCount')::integer>0 group by coalesce(r->>'partyId',r->>'id')) blocks)),(select key from test_ops))$$,'intact groups can be formed without slots');
select is((select count(*)::integer from app_private.registrations r where r.status='submitted' and exists(select 1 from app_private.registration_children c where c.registration_id=r.id and c.participation_status='active') and not exists(select 1 from app_private.group_registrations a where a.registration_id=r.id and a.superseded_at is null)),0,'every submitted registration assigned exactly once');
select throws_ok($$select api.admin_group_operations_apply('duindorp-halloween-2026','reset',(select impact->>'inputHash' from test_ops),'{"confirmation":"ALLE GROEPEN TERUGZETTEN"}',gen_random_uuid()::text)$$,'40001','STALE_GROUP_INPUT','old impact cannot reset a changed composition');
select * from finish();
rollback;
