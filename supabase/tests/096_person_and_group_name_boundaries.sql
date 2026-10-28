begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table identity_fixture(label text primary key,user_id uuid,household_id uuid,registration_id uuid,group_id uuid,conversation_id uuid,party_id uuid);
create function pg_temp.name_fixture(_label text,_name text,_group_number integer,_original text default null)
returns uuid language plpgsql as $$
declare u uuid:=gen_random_uuid(); h uuid:=gen_random_uuid(); r uuid:=gen_random_uuid(); g uuid; c uuid; child uuid;
  e uuid:=(select id from app_private.events where slug='duindorp-halloween-2026');
begin
  insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values(u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',u::text||'@example.invalid',now(),'{}','{}',now(),now());
  insert into app_private.profiles(user_id,display_name) values(u,_name) on conflict(user_id) do update set display_name=excluded.display_name;
  insert into app_private.households(id,label,primary_contact_user_id) values(h,'Gezelschap '||_label,u);
  insert into app_private.household_members(household_id,user_id,relation_role) values(h,u,'owner');
  insert into app_private.registrations(id,event_id,household_id,status,reference) values(r,e,h,'submitted','NAME-'||r::text);
  if _original is not null then insert into app_private.registration_drafts(event_id,household_id,payload)
    values(e,h,jsonb_build_object('adult',jsonb_build_object('name',_original))); end if;
  select id into g from app_private.walking_groups where event_id=e and system_number=_group_number;
  if g is null then insert into app_private.walking_groups(event_id,code,system_number,status)
    values(e,'NAME-'||_group_number,_group_number,'draft') returning id into g; end if;
  insert into app_private.children(household_id,first_name,age_at_event) values(h,'Synthetisch kind',8) returning id into child;
  insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents) values(e,r,child,250);
  insert into app_private.group_registrations(group_id,registration_id,assignment_revision) values(g,r,1);
  insert into app_private.messenger_conversations(event_id,participant_user_id,subject_kind,subject_id,created_by)
    values(e,u,'group',g,u) returning id into c;
  insert into app_private.messenger_messages(conversation_id,sender_id,sender_side,body)
    values(c,u,'participant','Originele berichtinhoud blijft exact bewaard.');
  insert into identity_fixture(label,user_id,household_id,registration_id,group_id,conversation_id) values(_label,u,h,r,g,c);
  return u;
end;
$$;
select pg_temp.name_fixture('G28','Zoë van der Meer',28,'Zoë van der Meer'),
  pg_temp.name_fixture('G02','Léa de Bruijn',2,'Léa de Bruijn'),
  pg_temp.name_fixture('G11','José van den Berg',11,'José van den Berg'),
  pg_temp.name_fixture('same-one','Robin van Dijk',46,'Robin van Dijk'),
  pg_temp.name_fixture('same-two','Robin van Dijk',46,'Robin van Dijk'),
  pg_temp.name_fixture('missing',null,46),
  pg_temp.name_fixture('derived','G-28',46,'Élodie de la Croix');
create temp table identity_preserved as select
  (select md5(jsonb_agg(to_jsonb(m) order by m.id)::text) from app_private.messenger_messages m) messages,
  (select md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.messenger_conversations c) conversations,
  (select md5(jsonb_agg(to_jsonb(a) order by a.id)::text) from app_private.group_registrations a) assignments,
  (select md5(jsonb_agg(to_jsonb(p) order by p.user_id)::text) from app_private.profiles p) profiles,
  (select md5(jsonb_agg(to_jsonb(o) order by o.id)::text) from app_private.email_outbox o) mail;
select is(app_private.messenger_subject_metadata(g.event_id,'group',g.id,f.user_id)->>'subjectLabel',
  p.display_name||' · '||g.system_code,'inbox uses the specific person followed by the group context, including reported G-28/G-02/G-11 cases')
from identity_fixture f join app_private.walking_groups g on g.id=f.group_id join app_private.profiles p on p.user_id=f.user_id where f.label in('G28','G02','G11');
select is(app_private.messenger_conversation_payload(conversation_id,true,'f0000000-0000-0000-0000-000000000001')->>'personName',
  'Zoë van der Meer','existing persisted conversation resolves the full person name after reload') from identity_fixture where label='G28';
select is(app_private.messenger_conversation_payload(conversation_id,true,'f0000000-0000-0000-0000-000000000001')#>>'{messages,0,senderName}',
  'Zoë van der Meer','message sender name uses its own account, preserving accents and particles') from identity_fixture where label='G28';
select is(app_private.messenger_subject_metadata(g.event_id,'group',g.id,f.user_id)->>'personName',null::text,'a genuinely missing name remains absent rather than inferred from email')
from identity_fixture f join app_private.walking_groups g on g.id=f.group_id where f.label='missing';
select is(app_private.messenger_subject_metadata(g.event_id,'group',g.id,f.user_id)->>'subjectLabel','Deelnemer · G-46','missing person has a neutral label and separate group code')
from identity_fixture f join app_private.walking_groups g on g.id=f.group_id where f.label='missing';
select is(app_private.participant_person_name(g.event_id,f.user_id),'Élodie de la Croix','an exact actual group identifier cannot mask an unambiguous original contact name')
from identity_fixture f join app_private.walking_groups g on g.id=f.group_id where f.label='derived';
select is((select display_name from app_private.profiles where user_id=(select user_id from identity_fixture where label='derived')),'G-28','read-time repair never rewrites stored account names');
select is((select count(distinct user_id)::integer from identity_fixture where label in('same-one','same-two')),2,'same-named people retain distinct account identities');
select is((select count(distinct conversation_id)::integer from identity_fixture where label in('same-one','same-two')),2,'same-named contacts retain their own conversations');
select is((select md5(jsonb_agg(to_jsonb(m) order by m.id)::text) from app_private.messenger_messages m),(select messages from identity_preserved),'reading corrected names preserves message contents and sender links');
select is((select md5(jsonb_agg(to_jsonb(c) order by c.id)::text) from app_private.messenger_conversations c),(select conversations from identity_preserved),'reading corrected names preserves conversation subjects and access links');
select is((select md5(jsonb_agg(to_jsonb(a) order by a.id)::text) from app_private.group_registrations a),(select assignments from identity_preserved),'reading corrected names preserves walking assignments');
select is((select md5(jsonb_agg(to_jsonb(p) order by p.user_id)::text) from app_private.profiles p),(select profiles from identity_preserved),'reading corrected names preserves all account records');
select is((select md5(jsonb_agg(to_jsonb(o) order by o.id)::text) from app_private.email_outbox o),(select mail from identity_preserved),'existing outbox status, recipients and payloads remain byte-for-byte unchanged');
-- Switch only the fixture's walking assignment. The historical thread still
-- identifies its actual participant and retains its original subject boundary.
update app_private.group_registrations set superseded_at=clock_timestamp() where registration_id=(select registration_id from identity_fixture where label='G28') and superseded_at is null;
insert into app_private.group_registrations(group_id,registration_id,assignment_revision)
select (select group_id from identity_fixture where label='G11'),registration_id,2 from identity_fixture where label='G28';
select is(app_private.messenger_conversation_payload(conversation_id,true,'f0000000-0000-0000-0000-000000000001')->>'personName','Zoë van der Meer','historical conversation still resolves its participant after group reassignment') from identity_fixture where label='G28';
select is(app_private.messenger_conversation_payload(conversation_id,true,'f0000000-0000-0000-0000-000000000001')->>'groupCode','G-28','historical conversation retains its original group subject') from identity_fixture where label='G28';
select ok(not app_private.messenger_actor_can_use_subject(g.event_id,f.user_id,'group',g.id),'name repair does not grant access to a former group')
from identity_fixture f join app_private.walking_groups g on g.id=f.group_id where label='G28';
select throws_ok($$select app_private.messenger_conversation_payload((select conversation_id from identity_fixture where label='G28'),false,(select user_id from identity_fixture where label='G28'))$$,
  '42501','NOT_AUTHORIZED','historical group access stays enforced');
select ok(not has_function_privilege('authenticated','app_private.participant_person_identity(uuid,uuid)','execute'),'raw identity resolver remains private');
select ok(not has_function_privilege('anon','api.admin_messenger_snapshot(text)','execute'),'corrected inbox remains organizer-scoped');
-- Context/read RPC sees the new group, while the old thread remains immutable.
select set_config('request.jwt.claims',jsonb_build_object('sub',user_id,'role','authenticated')::text,true) from identity_fixture where label='G28';
select is(api.participant_messenger_context('duindorp-halloween-2026','walker',(select group_id from identity_fixture where label='G11'),null,null)->>'personName','Zoë van der Meer','participant context uses own person identity in the new group');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select ok((select bool_and(item ? 'personName') from jsonb_array_elements(api.admin_registrations_snapshot('duindorp-halloween-2026')) item),'registration overview exposes explicit person names');
select ok((select bool_and(reg ? 'personName') from jsonb_array_elements(api.admin_group_composition_snapshot('duindorp-halloween-2026')->'groups') grp cross join jsonb_array_elements(grp->'registrations') reg),'group composition exposes each registration person independently');
-- The source and target both have multiple households; do not present a
-- randomly selected person's name as the entire merged party's name.
insert into app_private.together_parties(event_id,public_label,creator_household_id,invite_token_hash,expires_at)
select e.id,'Samenloopfixture',f.household_id,extensions.gen_random_bytes(32),now()+interval '1 year'
from identity_fixture f cross join app_private.events e where e.slug='duindorp-halloween-2026' and f.label in('same-one','same-two');
update identity_fixture f set party_id=p.id from app_private.together_parties p where p.creator_household_id=f.household_id and f.label in('same-one','same-two');
insert into app_private.together_memberships(party_id,registration_id)
select (select party_id from identity_fixture where label='same-one'),registration_id from identity_fixture where label in('same-one','G11')
union all select (select party_id from identity_fixture where label='same-two'),registration_id from identity_fixture where label in('same-two','missing');
create temp table name_merge_request(id uuid);
with request as (insert into app_private.together_join_requests(event_id,source_party_id,target_party_id,requested_by_registration_id,requested_code,child_count_at_request,group_limit_at_request)
select e.id,(select party_id from identity_fixture where label='same-one'),(select party_id from identity_fixture where label='same-two'),
  (select registration_id from identity_fixture where label='same-one'),r.together_code,2,15
from app_private.events e join app_private.registrations r on r.id=(select registration_id from identity_fixture where label='same-two') where e.slug='duindorp-halloween-2026' returning id)
insert into name_merge_request select id from request;
select lives_ok($$select api.admin_decide_together_request((select id from name_merge_request),1,'accept',false,
  'Geïsoleerde naamproef voor alle oorspronkelijke gezelschappen')$$,'real organizer approval merges original together memberships');
select is((select count(*)::integer from app_private.together_memberships where party_id=(select party_id from identity_fixture where label='same-two') and left_at is null),4,
  'actual merge retains all four original registration identities');
select is(app_private.messenger_conversation_payload(conversation_id,true,'f0000000-0000-0000-0000-000000000001')->>'personName','Robin van Dijk',
  'an existing conversation retains the actual participant name after together merge') from identity_fixture where label='same-one';
select is((select count(*)::integer from app_private.email_outbox where message_type='group_merge_approved' and payload->>'requestId'=(select id::text from name_merge_request)),4,'multi-household approval preserves one notification per original adult recipient');
select ok((select bool_and(not (payload ? 'headGroup') and not (payload ? 'groupName')) from app_private.email_outbox where message_type='group_merge_approved' and payload->>'requestId'=(select id::text from name_merge_request)),
  'group code is not placed in a person-like head-group/name field');
select ok((select bool_and(payload->>'groupCode'='G-46') from app_private.email_outbox where message_type='group_merge_approved' and payload->>'requestId'=(select id::text from name_merge_request)),
  'G-46 stays separate walking-group context in a together approval');
select ok((select bool_and(payload->>'personName' is not distinct from app_private.participant_person_name(r.event_id,o.recipient_ref::uuid)) from app_private.email_outbox o
  join app_private.together_join_requests r on r.id::text=o.payload->>'requestId' where o.message_type='group_merge_approved' and r.id=(select id from name_merge_request)),
  'each recipient gets its own name rather than another household contact');
select ok((select bool_and(member ? 'personName') from app_private.together_management_parties((select id from app_private.events where slug='duindorp-halloween-2026')) p cross join jsonb_array_elements(p.projection->'members') member),
  'together administration exposes original household contacts separately');
-- New walking-group mails carry a personal greeting alongside group context.
insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
select 'name-group-fixture:'||f.user_id,'group_composition_confirmed',f.user_id::text,u.email,
  jsonb_build_object('groupId',f.group_id,'groupCode','G-46','groupName','G-46') from identity_fixture f join auth.users u on u.id=f.user_id where label='same-one';
select is((select payload->>'personName' from app_private.email_outbox where dedupe_key like 'name-group-fixture:%'),'Robin van Dijk','new group confirmation mail greets its recipient independently of the group label');
-- Exercise the actual time-notification materializer, which used to rebuild
-- a narrower payload and would otherwise discard the new enqueue-time name.
update app_private.event_route_settings set first_start_at='2026-10-31T16:00:00Z',global_ordinary_stop_at='2026-10-31T19:30:00Z',
  final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T18:00:00Z',
  finale_last_arrival_at='2026-10-31T20:30:00Z',finale_closes_at='2026-10-31T21:00:00Z',finale_max_concurrent_groups=20,
  finale_max_concurrent_children=500,planner_mode='dynamic' where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
create temp table identity_time_mail(schedule jsonb,mail_id uuid,material jsonb);
insert into identity_time_mail(schedule) select api.admin_startregie_move_group((select group_id from identity_fixture where label='same-one'),
  '20000000-0000-0000-0000-000000000001','2026-10-31T16:00:00Z',
  (select g.version from app_private.walking_groups g join identity_fixture f on f.group_id=g.id where f.label='same-one'),'neutral','Geïsoleerde tijdmailproef met correcte ontvangeridentiteit');
select lives_ok($$select api.admin_startregie_confirm_and_send('duindorp-halloween-2026',
  (select jsonb_build_array(jsonb_build_object('id',schedule->>'id','revision',(schedule->>'revision')::integer)) from identity_time_mail),
  (select settings_version from app_private.events where slug='duindorp-halloween-2026'),gen_random_uuid()::text)$$,
  'actual confirmation queues recipient-specific time notifications');
update identity_time_mail set mail_id=(select o.id from app_private.email_outbox o where o.message_type='group_schedule_published'
  and o.recipient_ref=(select user_id::text from identity_fixture where label='same-one')
  and o.payload->>'groupId'=(select group_id::text from identity_fixture where label='same-one') order by o.created_at desc limit 1);
select is((select o.payload->>'personName' from app_private.email_outbox o join identity_time_mail t on t.mail_id=o.id),'Robin van Dijk',
  'time notification is enqueued with its exact recipient name');
update identity_time_mail set material=api.worker_group_schedule_mail_payload(mail_id);
select is((select material->>'personName' from identity_time_mail),'Robin van Dijk','worker materialization preserves the recipient name up to final mail rendering');
select is((select o.payload->>'personName' from app_private.email_outbox o join identity_time_mail t on t.mail_id=o.id),'Robin van Dijk',
  'worker persists the same safe named payload for future correction history');

select is(app_private.usable_person_name((select id from app_private.events where slug='duindorp-halloween-2026'),'person@example.invalid'),null::text,
  'email addresses are never treated as personal names');
select is(app_private.usable_person_name((select id from app_private.events where slug='duindorp-halloween-2026'),E'Voornaam\nAchternaam'),null::text,
  'control characters are rejected consistently with the frontend');
select is(app_private.usable_person_name((select id from app_private.events where slug='duindorp-halloween-2026'),'G–999'),null::text,
  'identifier-shaped labels are not person-name fallbacks');
select is(app_private.usable_person_name((select id from app_private.events where slug='duindorp-halloween-2026'),'  Élodie van der Waals  '),'Élodie van der Waals',
  'name spelling, accents and particles are preserved while surrounding whitespace is trimmed');
select pg_temp.name_fixture('ambiguous',null,46,'Eerste oorspronkelijke contact');
insert into app_private.households(label,primary_contact_user_id) select 'Tweede contactbron',user_id from identity_fixture where label='ambiguous';
insert into app_private.registration_drafts(event_id,household_id,payload)
select e.id,h.id,'{"adult":{"name":"Andere oorspronkelijke contact"}}'::jsonb from app_private.events e cross join app_private.households h
where e.slug='duindorp-halloween-2026' and h.label='Tweede contactbron' and h.primary_contact_user_id=(select user_id from identity_fixture where label='ambiguous');
select is(app_private.participant_person_name((select id from app_private.events where slug='duindorp-halloween-2026'),user_id),null::text,
  'conflicting original contact names produce neutral identity rather than an arbitrary household contact') from identity_fixture where label='ambiguous';
-- The owner's registration contact must never name a different adult account.
insert into app_private.household_members(household_id,user_id,relation_role)
select f.household_id,(select user_id from identity_fixture where label='missing'),'adult' from identity_fixture f where f.label='G02';
select is(app_private.participant_person_name((select id from app_private.events where slug='duindorp-halloween-2026'),user_id),null::text,
  'an adult without a personal name cannot inherit another primary contact name') from identity_fixture where label='missing';

select * from finish();
rollback;
