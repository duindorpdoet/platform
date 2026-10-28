begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table large_chain(eid uuid,registration_id uuid,proposal jsonb,plan jsonb,group_id uuid,schedule_id uuid,start_id uuid,run_id uuid,stop_id uuid,point_version integer,event_version integer,payment_batch jsonb,preview jsonb,arrived jsonb,first_token text,run_version integer);
insert into large_chain(eid) select id from app_private.events where slug='duindorp-halloween-2026';
grant select,update on large_chain to authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update large_chain set preview=api.admin_group_size_policy_preview('duindorp-halloween-2026',45,null);
select lives_ok($$select api.admin_group_size_policy_save('duindorp-halloween-2026',45,null,(select (preview->>'settingsVersion')::integer from large_chain),(select preview->>'impactHash' from large_chain),'Expliciete geïsoleerde ketenproef met vijfenveertig kinderen')$$,'organizer saves a real event maximum of 45');
select set_config('request.jwt.claims','{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select lives_ok($$select api.registration_save_draft('duindorp-halloween-2026',jsonb_build_object('adult',jsonb_build_object('name','Fictieve grote testfamilie','phone','0612345678'),'children',(select jsonb_agg(jsonb_build_object('name','Ketenproefkind '||n,'age','9','accessibilityNote','')) from generate_series(1,45)n),'marketingConsent',false),null)$$,'real registration draft accepts 45 children without a hidden 20 cap');
update large_chain set registration_id=(api.registration_submit('duindorp-halloween-2026','test-v1','test-v1',gen_random_uuid()::text,'large-group-full-chain')->>'id')::uuid;
set local role postgres;
select is((select count(*)::integer from app_private.registration_children where registration_id=(select registration_id from large_chain)),45,'real submission persists every child');
select is((select count(*)::integer from app_private.payment_requests where registration_id=(select registration_id from large_chain)),1,'one real registration payment request is created');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update large_chain set payment_batch=api.admin_child_payment_publish('duindorp-halloween-2026',
 (select jsonb_agg(jsonb_build_object('id',c.child_id,'version',c.payment_version)) from app_private.registration_children c where c.registration_id=large_chain.registration_id),
 (select child_id from app_private.registration_children where registration_id=large_chain.registration_id limit 1),
 'https://tikkie.me/pay/isolated-large-chain','Geïsoleerde betaling voor alle vijfenveertig testkinderen',gen_random_uuid()::text);
select lives_ok($$select api.admin_child_payment_confirm((select (payment_batch->>'id')::uuid from large_chain),(select (payment_batch->>'version')::integer from large_chain),(select (payment_batch->>'totalAmountCents')::integer from large_chain),'isolated-large-chain','Werkelijke betaalbevestiging via de bestaande commandogrens',gen_random_uuid()::text)$$,'existing child payment command confirms all 45 without changing the payment path');
update app_private.portal_windows set opens_at=clock_timestamp()-interval '1 hour',closes_at=clock_timestamp()+interval '5 hours',max_children_per_visit=100;
update app_private.event_route_settings set first_start_at=date_bin(interval '10 minutes',statement_timestamp(),'2000-01-01Z'::timestamptz)-interval '30 minutes',global_ordinary_stop_at=clock_timestamp()+interval '1 hour',
 final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at=clock_timestamp(),finale_last_arrival_at=clock_timestamp()+interval '4 hours',finale_closes_at=clock_timestamp()+interval '5 hours',
 ordinary_visit_seconds=60,route_buffer_seconds=0,finale_max_concurrent_groups=10,finale_max_concurrent_children=100,finale_available=true,planner_mode='dynamic' where event_id=(select eid from large_chain);
update app_private.start_points set max_gathering_children=18,max_gathering_groups=10 where id='20000000-0000-0000-0000-000000000001';
update large_chain set point_version=p.version from app_private.start_points p where p.id='20000000-0000-0000-0000-000000000001';
do $$begin perform api.admin_startregie_verify_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select point_version from large_chain),true,'Fictieve veilige vertrekstoep voor de grote ketenproef');end $$;
with slot as(insert into app_private.start_slots(event_id,start_point_id,name,location_name,starts_at,max_groups,max_children) select eid,'20000000-0000-0000-0000-000000000001','Fictief groot startslot','Fictieve vertrekplek',date_bin(interval '10 minutes',statement_timestamp(),'2000-01-01Z'::timestamptz)-interval '10 minutes',10,100 from large_chain returning id) update large_chain set start_id=slot.id from slot;
update large_chain set proposal=jsonb_build_object('groups',jsonb_build_array(jsonb_build_object('startId',start_id,'partyIds',jsonb_build_array(registration_id),'childCount',45,'expectedFinaleArrivalAt',clock_timestamp()+interval '75 minutes','preferenceMatch','neutral')));
select throws_ok($$select api.admin_apply_dynamic_plan('duindorp-halloween-2026',(select proposal from large_chain),app_private.start_planning_input_hash((select eid from large_chain)),gen_random_uuid()::text,'fixture')$$,'23514','START_POINT_CAPACITY_EXCEEDED','maximum 45 never overrides a physical start point capacity of 18');
select is((select count(*)::integer from app_private.group_registrations where registration_id=(select registration_id from large_chain)),0,'failed physical capacity leaves no partial group assignment');
update app_private.start_points set max_gathering_children=100 where id='20000000-0000-0000-0000-000000000001';
-- Capacity edits change the point revision and intentionally require a new explicit review.
update large_chain set point_version=p.version from app_private.start_points p where p.id='20000000-0000-0000-0000-000000000001';
do $$begin if not app_private.start_point_safe_connection('20000000-0000-0000-0000-000000000001') then perform api.admin_startregie_verify_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select point_version from large_chain),true,'Fictieve hercontrole na de capaciteitswijziging');end if;end $$;
update large_chain set plan=api.admin_apply_dynamic_plan('duindorp-halloween-2026',proposal,app_private.start_planning_input_hash(eid),gen_random_uuid()::text,'fixture');
update large_chain set schedule_id=(plan#>>'{scheduleIds,0}')::uuid;
update large_chain c set group_id=s.group_id,event_version=e.settings_version from app_private.group_schedule_revisions s,app_private.events e where s.id=c.schedule_id and e.id=c.eid;
select is((select count(*)::integer from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id where a.group_id=(select group_id from large_chain) and a.superseded_at is null),45,'actual dynamic plan assigns the intact 45-child registration');
do $$begin
 perform api.admin_startregie_confirm_start('duindorp-halloween-2026',(select group_id from large_chain),1,(select event_version from large_chain));
 perform api.admin_startregie_publish_times('duindorp-halloween-2026',array[(select schedule_id from large_chain)],jsonb_build_array(jsonb_build_object('id',(select schedule_id from large_chain),'revision',1)),(select event_version from large_chain),gen_random_uuid()::text);
 perform api.admin_assign_group_leader((select group_id from large_chain),'c0000000-0000-0000-0000-000000000001',(select version from app_private.walking_groups where id=(select group_id from large_chain)),'Afzonderlijke leider voor de werkelijke grote ketenproef');
end $$;
select is((select count(*)::integer from app_private.poortenboek_passport_seals where team_id=(select group_id from large_chain)),0,'publishing a large group never awards a fictitious seal');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update large_chain set run_id=(api.run_start(group_id,array(select c.id from app_private.registration_children c where c.registration_id=large_chain.registration_id),(select version from app_private.walking_groups where id=large_chain.group_id),'large-chain-start','large-chain-start')->>'runId')::uuid;
select is((select count(*)::integer from app_private.run_participants where run_id=(select run_id from large_chain) and attendance='present'),45,'all 45 children start through the real run command');
select is(jsonb_array_length(api.group_snapshot((select group_id from large_chain))#>'{run,participants}'),45,'the real leader roster contains all 45 children');
update large_chain c set stop_id=r.current_stop_id from app_private.group_runs r where r.id=c.run_id;
update large_chain c set first_token='TEST-PORTAL-'||lpad(p.system_number::text,2,'0')||'-TOKEN' from app_private.run_stops s join app_private.portals p on p.id=s.portal_id where s.id=c.stop_id;
update large_chain c set run_version=r.version from app_private.group_runs r where r.id=c.run_id;
update large_chain c set arrived=api.run_arrive_and_advance(run_id,stop_id,run_version,first_token,(select jsonb_object_agg(id::text,'skipped') from app_private.run_participants where run_id=c.run_id),'large-chain-arrival');
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run_id from large_chain)),45,'every present child receives a real immutable arrival even when staying outside');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from large_chain)),45,'all 45 personal books receive exactly one inclusive seal');
select lives_ok($$select api.run_arrive_and_advance((select run_id from large_chain),(select stop_id from large_chain),(select run_version from large_chain),(select first_token from large_chain),(select jsonb_object_agg(id::text,'skipped') from app_private.run_participants where run_id=(select run_id from large_chain)),'large-chain-arrival')$$,'an exact arrival retry remains safe');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from large_chain)),45,'retry never doubles the 45 personal seals');
-- The actual child-session projection sees each child's own seal in the large group.
insert into app_private.poortenboek_codes(event_id,child_id,code_digest,ciphertext)
select c.event_id,c.child_id,encode(extensions.digest(c.child_id::text||'large-code','sha256'),'hex'),repeat('encrypted',8)
from app_private.registration_children c where c.registration_id=(select registration_id from large_chain);
insert into app_private.poortenboek_sessions(code_id,token_hash)
select code.id,encode(extensions.digest(code.child_id::text||'large-session','sha256'),'hex')
from app_private.poortenboek_codes code join app_private.registration_children c on c.child_id=code.child_id and c.event_id=code.event_id
where c.registration_id=(select registration_id from large_chain);
select is((select count(*)::integer from app_private.poortenboek_sessions session join app_private.poortenboek_codes code on code.id=session.code_id
 join app_private.registration_children c on c.child_id=code.child_id and c.event_id=code.event_id
 where c.registration_id=(select registration_id from large_chain)
 and jsonb_array_length(api.poortenboek_child_action(session.token_hash,'snapshot')#>'{journey,seals}')=1),45,'all 45 real child session projections have their own single personal seal');
select ok(not exists(select 1 from app_private.poortenboek_sessions session join app_private.poortenboek_codes code on code.id=session.code_id
 join app_private.registration_children c on c.child_id=code.child_id and c.event_id=code.event_id
 where c.registration_id=(select registration_id from large_chain)
 and api.poortenboek_child_action(session.token_hash,'snapshot')->'start'->>'canStart'<>'true'),'the child book reads the same actually started publication');
select * from finish();
rollback;
