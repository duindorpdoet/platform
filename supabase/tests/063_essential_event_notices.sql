begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

create temp table essential_results(key text primary key,value jsonb) on commit drop;
grant select,insert on essential_results to authenticated;

insert into app_private.participant_preferences(event_id,user_id,email_updates,optional_updates_consent)
select id,'a0000000-0000-0000-0000-000000000001',false,false
from app_private.events where slug='duindorp-halloween-2026'
on conflict(event_id,user_id) do update set email_updates=false,optional_updates_consent=false;
update app_private.participant_preferences set editorial_unsubscribed_at=now()
where user_id='a0000000-0000-0000-0000-000000000001';
insert into essential_results select 'preferences',to_jsonb(p)
from app_private.participant_preferences p join app_private.events e on e.id=p.event_id
where e.slug='duindorp-halloween-2026' and p.user_id='a0000000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_publish_participant_update('duindorp-halloween-2026','all','Veilig vertrek','Neem de veilige oversteek.','urgent',false)$$,
 '42501','NOT_AUTHORIZED','essential delivery does not give a participant publication rights');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into essential_results values('normal',api.admin_publish_participant_update('duindorp-halloween-2026','walker','Gewone update','Een gewone evenementupdate.','normal',true));
insert into essential_results values('important',api.admin_publish_participant_update('duindorp-halloween-2026','walker','Veilige oversteek','Gebruik de gecontroleerde oversteek.','important',false));
insert into essential_results values('urgent',api.admin_publish_participant_update('duindorp-halloween-2026','walker','Route aangepast','Volg de aanwijzingen van de organisatie.','urgent',false));
set local role postgres;

select is((select count(*)::int from app_private.email_outbox where payload->>'title'='Gewone update' and recipient_email='parent-a@example.invalid'),0,'ordinary updates still respect the email preference');
select is((select count(*)::int from app_private.email_outbox where payload->>'title'='Veilige oversteek' and recipient_email='parent-a@example.invalid'),1,'important update reaches an unsubscribed participant even when client requests no email');
select is((select count(*)::int from app_private.email_outbox where payload->>'title'='Route aangepast' and recipient_email='parent-a@example.invalid'),1,'urgent update reaches an unsubscribed participant');
select is((select payload->>'mandatoryEventNotice' from app_private.email_outbox where payload->>'title'='Veilige oversteek' and recipient_email='parent-a@example.invalid'),'true','the server records the necessary-event-notice purpose');
select is((select message_type from app_private.email_outbox where payload->>'title'='Veilige oversteek' and recipient_email='parent-a@example.invalid'),'participant_update','necessary notices use the transactional worker, independent of newsletter sending');
select is((select to_jsonb(p) from app_private.participant_preferences p join app_private.events e on e.id=p.event_id where e.slug='duindorp-halloween-2026' and p.user_id='a0000000-0000-0000-0000-000000000001'),(select value from essential_results where key='preferences'),'newsletter opt-out and the complete preference history remain unchanged');
select is((select value->>'mandatoryEventNotice' from essential_results where key='important'),'true','publication reports that mandatory delivery was applied');
select is((select minimal_change->>'mandatoryEventNotice' from app_private.audit_events where action='participant.update_published' and resource_id=(select (value->>'id')::uuid from essential_results where key='important')),'true','the organizer decision and delivery policy are audited');
select is((select count(*)::int from app_private.email_outbox where payload->>'title'='Veilige oversteek' and recipient_email='owner@example.invalid'),0,'role targeting still excludes unrelated homeowner accounts');

-- A registration created after the first notice is eligible for the next one.
insert into auth.users(id,email,email_confirmed_at) values
 ('63000000-0000-0000-0000-000000000001','new-essential@example.invalid',now()),
 ('63000000-0000-0000-0000-000000000002','applicant-essential@example.invalid',now());
insert into app_private.households(id,label,primary_contact_user_id) values('63000000-0000-0000-0000-000000000003','Nieuw gezin','63000000-0000-0000-0000-000000000001');
insert into app_private.household_members(household_id,user_id,relation_role) values('63000000-0000-0000-0000-000000000003','63000000-0000-0000-0000-000000000001','owner');
insert into app_private.registrations(event_id,household_id,status,reference,submitted_at)
select id,'63000000-0000-0000-0000-000000000003','submitted','DPH-2026-ESSENTIAL',now() from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.portal_applications(event_id,applicant_user_id,review_status,submitted_at)
select id,'63000000-0000-0000-0000-000000000002','submitted',now() from app_private.events where slug='duindorp-halloween-2026';

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into essential_results values('new',api.admin_publish_participant_update('duindorp-halloween-2026','all','Iedereen veilig op pad','Controleer de laatste aanwijzingen voor vertrek.','important',false));
set local role postgres;
select is((select count(*)::int from app_private.email_outbox where payload->>'title'='Iedereen veilig op pad' and recipient_email='new-essential@example.invalid'),1,'a new registration is included without an opt-in backfill or scheduled sync');
select is((select count(*)::int from app_private.email_outbox where payload->>'title'='Iedereen veilig op pad' and recipient_email='applicant-essential@example.invalid'),1,'a pending house applicant also receives necessary event information');
select is((select payload->>'actionPath' from app_private.email_outbox where payload->>'title'='Iedereen veilig op pad' and recipient_email='applicant-essential@example.invalid'),'/omgeving','a pending applicant is directed to their own available environment');
select ok(not exists(select 1 from app_private.participant_preferences where user_id='63000000-0000-0000-0000-000000000001' and optional_updates_consent),'new participants are not falsely recorded as newsletter opt-ins');
select is((select count(*)::int from app_private.email_outbox where payload->>'title'='Iedereen veilig op pad' and recipient_email='parent-a@example.invalid'),1,'multiple participant roles never duplicate a notice');

update app_private.registrations set status='cancelled' where household_id='63000000-0000-0000-0000-000000000003';
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into essential_results values('after-cancel',api.admin_publish_participant_update('duindorp-halloween-2026','all','Veiligheidscontrole','Volg de actuele instructies.','urgent',false));
set local role postgres;
select is((select count(*)::int from app_private.email_outbox where payload->>'title'='Veiligheidscontrole' and recipient_email='new-essential@example.invalid'),0,'a cancelled registration is no longer in the active event audience');
select is((select count(*)::int from app_private.email_outbox where payload->>'title'='Veiligheidscontrole' and recipient_email='applicant-essential@example.invalid'),1,'remaining participants stay eligible for the next notice');
select ok(not has_function_privilege('anon','api.admin_publish_participant_update(text,text,text,text,text,boolean)','execute'),'anonymous callers cannot publish or use the mandatory recipient policy');
select * from finish();
rollback;
