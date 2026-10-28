begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table communication(eid uuid,gid uuid,point_id uuid,schedule_id uuid,revision integer,mail_id uuid,first_mail uuid,material jsonb,first_time timestamptz,key text default gen_random_uuid()::text,result jsonb);
insert into communication(eid,gid,point_id,first_time) select id,'23000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','2026-10-31T17:00:00Z' from app_private.events where slug='duindorp-halloween-2026';
update app_private.event_route_settings set first_start_at='2026-10-31T15:00:00Z',global_ordinary_stop_at='2026-10-31T19:30:00Z',final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T18:00:00Z',finale_last_arrival_at='2026-10-31T20:30:00Z',finale_closes_at='2026-10-31T21:00:00Z',finale_max_concurrent_groups=10,finale_max_concurrent_children=100,finale_available=true,planner_mode='dynamic' where event_id=(select eid from communication);
select app_private.withdraw_group_appointment((select gid from communication),'Afzonderlijke fixture zonder eerder gedeelde tijd');
-- This communication-only fixture isolates the physical departure from other seeded groups.
select app_private.withdraw_group_appointment(id,'Andere seedafspraken buiten de geïsoleerde communicatieproef')
from app_private.walking_groups where event_id=(select eid from communication) and id<>(select gid from communication);
update app_private.payment_requests set status='awaiting_link' where registration_id in(select registration_id from app_private.group_registrations where group_id=(select gid from communication) and superseded_at is null);
select api.admin_startregie_confirm_point('duindorp-halloween-2026',point_id,(select version from app_private.start_points where id=point_id)) from communication;
do $$declare i integer;begin for i in 1..3 loop
 update communication set schedule_id=(api.admin_startregie_move_group(gid,point_id,first_time+make_interval(mins=>i*10),(select version from app_private.walking_groups where id=gid),'neutral','Drie interne conceptrevisies zonder verzendtoestemming')->>'id')::uuid;
end loop;end $$;
update communication set revision=(select s.revision from app_private.group_schedule_revisions s where s.id=schedule_id);
select is((select count(*)::integer from app_private.email_outbox where message_type in ('group_schedule_published','group_schedule_corrected') and payload->>'groupId'=(select gid::text from communication)),0,'draft revisions do not mail');
select lives_ok($$update communication set result=api.admin_startregie_confirm_and_send('duindorp-halloween-2026',jsonb_build_array(jsonb_build_object('id',schedule_id,'revision',revision)),(select settings_version from app_private.events where id=eid),key)$$,'one explicit action confirms, publishes and queues unpaid starts');
select is(api.admin_startregie_confirm_and_send('duindorp-halloween-2026',jsonb_build_array(jsonb_build_object('id',schedule_id,'revision',revision)),(select settings_version from app_private.events where id=eid),key),result,'combined confirmation is idempotent') from communication;
update communication set first_mail=(select o.id from app_private.email_outbox o where o.payload->>'groupId'=gid::text and o.message_type='group_schedule_published' order by o.created_at limit 1);
select ok((select first_mail is not null from communication),'internal revision three receives first time confirmation');
update communication set material=api.worker_group_schedule_mail_payload(first_mail);
select is((select material->>'messageType' from communication),'group_schedule_published','first actual communication uses initial template');
select ok(not ((select material from communication) ?| array['startPoint','startAddress','address','coordinate','linkedPortalId']),'time mail payload never contains location, even after release');
-- A new location snapshot with an unchanged time must retain the pending first mail.
update app_private.start_points set name=name||' nieuwe poortnaam',version=version+1 where id=(select point_id from communication);
update communication set schedule_id=(api.admin_startregie_move_group(gid,point_id,(select slot.starts_at from app_private.group_schedule_revisions s join app_private.start_slots slot on slot.id=s.start_slot_id where s.id=communication.schedule_id),(select version from app_private.walking_groups where id=gid),'neutral','Alleen de poortlocatie opnieuw bevestigen')->>'id')::uuid;
update communication set revision=(select s.revision from app_private.group_schedule_revisions s where s.id=schedule_id);
select lives_ok($$select api.admin_startregie_confirm_and_send('duindorp-halloween-2026',jsonb_build_array(jsonb_build_object('id',schedule_id,'revision',revision)),(select settings_version from app_private.events where id=eid),gen_random_uuid()::text) from communication$$,'location-only revision can be confirmed');
select ok(api.worker_group_schedule_mail_payload(first_mail) is not null,'location-only revision preserves pending first time mail') from communication;
select is((select count(*)::integer from app_private.email_outbox where payload->>'groupId'=(select gid::text from communication) and message_type in ('group_schedule_published','group_schedule_corrected')),1,'no extra mail for a location-only publication');
update app_private.email_outbox set status='accepted',provider_id='fixture-provider-accepted' where id=(select first_mail from communication);
-- Two quick new times; neither intermediate draft is treated as the recipient-known old time.
do $$declare i integer;begin for i in 1..2 loop
 update communication set schedule_id=(api.admin_startregie_move_group(gid,point_id,first_time+make_interval(mins=>30+i*10),(select version from app_private.walking_groups where id=gid),'neutral','Werkelijke tijdwijziging als aparte bevestigde afspraak')->>'id')::uuid;
 update communication set revision=(select s.revision from app_private.group_schedule_revisions s where s.id=schedule_id);
 perform api.admin_startregie_confirm_and_send('duindorp-halloween-2026',jsonb_build_array(jsonb_build_object('id',(select schedule_id from communication),'revision',(select revision from communication))),(select settings_version from app_private.events where id=(select eid from communication)),gen_random_uuid()::text);
end loop;end $$;
update communication set mail_id=(select o.id from app_private.email_outbox o where o.payload->>'groupId'=gid::text and o.status='pending' order by o.created_at desc limit 1);
update communication set material=api.worker_group_schedule_mail_payload(mail_id);
select is((select material->>'messageType' from communication),'group_schedule_corrected','provider-known earlier time produces correction');
select is((select (material->>'oldStartsAt')::timestamptz from communication),'2026-10-31T17:30:00Z'::timestamptz,'old time is the actually communicated time, not unsent intermediate');
select is((select (material->>'startsAt')::timestamptz from communication),'2026-10-31T17:50:00Z'::timestamptz,'only latest time is current');
select is((select count(*)::integer from app_private.email_outbox where payload->>'groupId'=(select gid::text from communication) and status='pending' and message_type in ('group_schedule_published','group_schedule_corrected')),1,'intermediate pending time is suppressed');
select is((app_private.published_start_projection((select gid from communication),'2026-10-31T16:49:59Z')->>'addressReleased')::boolean,false,'first location remains secret before exact T-60');
select is((app_private.published_start_projection((select gid from communication),'2026-10-31T16:50:00Z')->>'addressReleased')::boolean,true,'own location released at exact T-60');
-- Reproduce a later provider callback on an older accepted SendGrid mail.
-- Deterministic timestamps model separate transactions inside this rollback-only test.
select api.worker_update_outbox((select mail_id from communication),'accepted','second-legacy-provider-id');
update app_private.email_outbox set provider='sendgrid' where id in(select first_mail from communication union all select mail_id from communication);
-- Older SendGrid material lost timeEventId/revision; its original semantic
-- identity still exists in the legacy group-schedule dedupe contract.
update app_private.email_outbox o set dedupe_key='group-schedule:'||(o.payload->>'groupId')||':'||p.revision||':'||o.recipient_ref
from app_private.start_time_communications t join app_private.group_start_publications p on p.publication_order=t.publication_order
where t.id=split_part(o.dedupe_key,':',2)::uuid and o.id in(select first_mail from communication union all select mail_id from communication);
update app_private.email_outbox set payload=payload-'timeEventId' where id in(select first_mail from communication union all select mail_id from communication);
select api.worker_store_email_event('late-old-start-delivery',(select first_mail from communication),'delivered',now());
alter table app_private.email_outbox disable trigger email_outbox_touch;
update app_private.email_outbox set updated_at=clock_timestamp()+interval '1 hour' where id=(select first_mail from communication);
alter table app_private.email_outbox enable trigger email_outbox_touch;
update communication set schedule_id=(api.admin_startregie_move_group(gid,point_id,first_time+interval '60 minutes',(select version from app_private.walking_groups where id=gid),'neutral','Nieuwe tijd na late callback op een oudere verzending')->>'id')::uuid;
update communication set revision=(select s.revision from app_private.group_schedule_revisions s where s.id=schedule_id);
select api.admin_startregie_confirm_and_send('duindorp-halloween-2026',jsonb_build_array(jsonb_build_object('id',schedule_id,'revision',revision)),(select settings_version from app_private.events where id=eid),gen_random_uuid()::text) from communication;
update communication set mail_id=(select o.id from app_private.email_outbox o where o.payload->>'groupId'=gid::text and o.status='pending' order by o.created_at desc limit 1);
update communication set material=api.worker_group_schedule_mail_payload(mail_id);
select is((select (material->>'oldStartsAt')::timestamptz from communication),'2026-10-31T17:50Z'::timestamptz,'late callback on an older mail never changes the last semantically communicated time');
select is((select (material->>'startsAt')::timestamptz from communication),'2026-10-31T18:00Z'::timestamptz,'the next correction retains the new published time');
select * from finish();
rollback;
