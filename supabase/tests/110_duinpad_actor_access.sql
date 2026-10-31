begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
insert into auth.users(id,email,email_confirmed_at) values
 ('b8100000-0000-4000-8000-000000000001','duinpad-actor@example.invalid',now()),
 ('b8100000-0000-4000-8000-000000000002','duinpad-other@example.invalid',now()),
 ('b8100000-0000-4000-8000-000000000003','duinpad-unverified@example.invalid',null);

select ok(not has_table_privilege('authenticated','app_private.duinpad_actor_access','select'),'browser cannot enumerate actor access');
select ok(not has_table_privilege('service_role','app_private.duinpad_actor_invitations','select'),'mail service cannot directly enumerate invitation hashes');
select ok(not has_function_privilege('anon','api.duinpad_actor_claim(text,text)','execute'),'anonymous invitation opening cannot claim');
select ok(not has_function_privilege('authenticated','api.duinpad_actor_finish(uuid,text,jsonb)','execute'),'a browser cannot invent a local execution receipt');
select ok(has_function_privilege('service_role','api.duinpad_actor_finish(uuid,text,jsonb)','execute'),'trusted backend can persist a physical result');
select ok(not has_function_privilege('authenticated','api.worker_duinpad_actor_invitation(uuid)','execute'),'an actor cannot read invitation mail material');
select ok(not has_function_privilege('service_role','app_private.worker_mail_prepare_before_duinpad_actor(text,text,uuid,uuid,text,text,text,jsonb,text,text)','execute'),'gateway cannot bypass latest invitation check');

create temp table actor_counts as select (select count(*) from app_private.registrations) registrations,(select count(*) from app_private.children) children,(select count(*) from app_private.portals) portals;
create temp table actor_case as select api.duinpad_actor_admin_command('duindorp-halloween-2026','invite',jsonb_build_object('name','Synthetische Acteur','email','Duinpad-Actor@Example.Invalid','invitationId','b8110000-0000-4000-8000-000000000001','tokenHash',repeat('a',64))) result;
select is((select result->'permissions' from actor_case),'[]'::jsonb,'new actors start with no rights');
select is((select count(*) from app_private.registrations),(select registrations from actor_counts),'actor invitation creates no participant registration');
select is((select count(*) from app_private.children),(select children from actor_counts),'actor invitation creates no child');
select is((select count(*) from app_private.portals),(select portals from actor_counts),'actor invitation creates no portal');
select is((select email from app_private.duinpad_actor_invitations where id='b8110000-0000-4000-8000-000000000001'),'duinpad-actor@example.invalid','invited email is normalized');
select is((select octet_length(token_hash) from app_private.duinpad_actor_invitations where id='b8110000-0000-4000-8000-000000000001'),32,'only a 32-byte token hash is persisted');
select ok(not((select payload from app_private.email_outbox where dedupe_key='actor-invitation:b8110000-0000-4000-8000-000000000001')?'token'),'durable invitation outbox contains no token');
select ok(not((select payload from app_private.email_outbox where dedupe_key='actor-invitation:b8110000-0000-4000-8000-000000000001')?'actionPath'),'durable invitation outbox contains no plaintext claim link');
select ok(not app_private.duinpad_actor_can((select id from app_private.events where slug='duindorp-halloween-2026'),'b8100000-0000-4000-8000-000000000001','heks.go'),'opening an invitation has no actor permission');
select lives_ok($$select api.duinpad_actor_admin_command('duindorp-halloween-2026','permissions',jsonb_build_object('id',result->>'id','revision',1,'permissions',jsonb_build_array('heks.go','zone1.trigger'))) from actor_case$$,'organizer explicitly assigns buttons');
select throws_ok($$select api.duinpad_actor_admin_command('duindorp-halloween-2026','permissions',jsonb_build_object('id',result->>'id','revision',1,'permissions',jsonb_build_array('stop-all'))) from actor_case$$,'40001','STALE_REVISION','stale form cannot overwrite a newer permission set');
select throws_ok($$select api.duinpad_actor_admin_command('duindorp-halloween-2026','permissions',jsonb_build_object('id',result->>'id','revision',2,'permissions',jsonb_build_array('zone5.stop'))) from actor_case$$,'23514',null,'no finale/heks emergency alias can be assigned as zonestop');

select set_config('request.jwt.claims','{"sub":"b8100000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select throws_ok($$select api.duinpad_actor_admin_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','login alone does not authorize actor management');
select throws_ok($$select api.duinpad_actor_claim('duindorp-halloween-2026',repeat('a',64))$$,'42501','INVITATION_WRONG_ACCOUNT','wrong verified Google/OTP account cannot claim');
select throws_ok($$select api.duinpad_actor_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','uninvited account has no actors room');
select set_config('request.jwt.claims','{"sub":"b8100000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select ok(not exists(select 1 from jsonb_array_elements(api.account_app_snapshot('duindorp-halloween-2026')->'environments') e where e->>'kind'='actor'),'pending invitation adds no chooser card');
select is(api.duinpad_actor_claim('duindorp-halloween-2026',repeat('a',64))->>'active','true','explicit verified claim activates existing identity');
select is(api.duinpad_actor_claim('duindorp-halloween-2026',repeat('a',64))->>'duplicate','true','repeated callbacks/claim are idempotent');
select is((select count(*) from app_private.duinpad_actor_access where user_id='b8100000-0000-4000-8000-000000000001'),1::bigint,'duplicate claims create no second actor account');
select is(api.duinpad_actor_snapshot('duindorp-halloween-2026')->'permissions','["heks.go","zone1.trigger"]'::jsonb,'actor sees only its explicit rights');
select ok(exists(select 1 from jsonb_array_elements(api.account_app_snapshot('duindorp-halloween-2026')->'environments') e where e->>'kind'='actor'),'active link adds existing environment chooser card');
select is(api.account_app_command('duindorp-halloween-2026','remember','{"kind":"adult","id":"actor"}')->>'path','/omgeving/acteur','existing account navigation remembers actor environment');
select is(api.account_app_snapshot('duindorp-halloween-2026')->'resume','{"kind":"adult","id":"actor"}'::jsonb,'actor resume remains authorized via current database access');

create temp table actor_payload as select jsonb_build_object('version','duinpad.actor.v1','command_id','b8120000-0000-4000-8000-000000000001','event_scope_id',(select id from app_private.events where slug='duindorp-halloween-2026'),'actor_subject','b8100000-0000-4000-8000-000000000001','permissions_revision',3,'action','zone1.trigger','group_id',null,'args','{}'::jsonb,'issued_at',extract(epoch from now()),'expires_at',extract(epoch from now())+8,'scope',jsonb_build_object('permission','zone1.trigger','internal_zones',jsonb_build_array(2)))::text payload;
select is((select api.duinpad_actor_reserve('duindorp-halloween-2026','b8120000-0000-4000-8000-000000000001',payload)->>'dispatch' from actor_payload),'true','current explicit permission reserves one command');
select is((select api.duinpad_actor_reserve('duindorp-halloween-2026','b8120000-0000-4000-8000-000000000001',payload)->>'dispatch' from actor_payload),'false','same immutable command returns receipt without redispatch');
select throws_ok($$select api.duinpad_actor_reserve('duindorp-halloween-2026','b8120000-0000-4000-8000-000000000001',(payload::jsonb||'{"args":{"other":true}}')::text) from actor_payload$$,'22023','COMMAND_CONFLICT','same command ID cannot change payload');
select is(api.duinpad_actor_finish('b8120000-0000-4000-8000-000000000001','unknown','{"ok":false,"unknown":true}')->>'status','unknown','unknown remains a separate durable outcome');
select throws_ok($$select api.duinpad_actor_reserve('duindorp-halloween-2026','b8120000-0000-4000-8000-000000000002',(payload::jsonb||'{"command_id":"b8120000-0000-4000-8000-000000000002"}')::text) from actor_payload$$,'23505',null,'unknown blocks blind new command IDs');
select is(api.duinpad_actor_receipt('duindorp-halloween-2026','b8120000-0000-4000-8000-000000000001')->>'status','unknown','owner can read its uncertain receipt');
select set_config('request.jwt.claims','{"sub":"b8100000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select throws_ok($$select api.duinpad_actor_receipt('duindorp-halloween-2026','b8120000-0000-4000-8000-000000000001')$$,'42501','NOT_AUTHORIZED','another account cannot read receipt or group');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.duinpad_actor_admin_command('duindorp-halloween-2026','reinvite',jsonb_build_object('id',result->>'id','email','duinpad-actor@example.invalid','invitationId','b8110000-0000-4000-8000-000000000002','tokenHash',repeat('b',64))) from actor_case$$,'reinvitation rotates link and requires another explicit claim');
select ok((select revoked_at is not null from app_private.duinpad_actor_invitations where id='b8110000-0000-4000-8000-000000000001'),'old invitation is revoked');
select is((select status::text from app_private.email_outbox where dedupe_key='actor-invitation:b8110000-0000-4000-8000-000000000001'),'suppressed','old queued invitation is suppressed');
select set_config('request.jwt.claims','{"sub":"b8100000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.duinpad_actor_claim('duindorp-halloween-2026',repeat('a',64))$$,'22023','INVITATION_UNAVAILABLE','old link cannot reclaim after reinvitation');
select throws_ok($$select api.duinpad_actor_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','old logged-in session cannot retain active actor rights while pending');
select is(api.duinpad_actor_claim('duindorp-halloween-2026',repeat('b',64))->>'active','true','replacement link explicitly activates same existing identity');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.duinpad_actor_admin_command('duindorp-halloween-2026','revoke',jsonb_build_object('id',result->>'id','revision',5)) from actor_case$$,'organization revokes access transactionally');
select set_config('request.jwt.claims','{"sub":"b8100000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.duinpad_actor_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','unchanged JWT no longer accesses actor snapshot after revocation');
select ok(not app_private.duinpad_actor_can((select id from app_private.events where slug='duindorp-halloween-2026'),'b8100000-0000-4000-8000-000000000001','zone1.trigger'),'revoked open page/direct API loses execution permission');
select ok(not exists(select 1 from jsonb_array_elements(api.account_app_snapshot('duindorp-halloween-2026')->'environments') e where e->>'kind'='actor'),'revocation removes actor chooser card');
select is(api.account_app_snapshot('duindorp-halloween-2026')->'resume','null'::jsonb,'revocation also removes actor resume');
select ok((select count(*) from app_private.audit_events where action like 'duinpad.actor.%')>=6,'claims, rights and commands leave minimal audits');
select ok(not exists(select 1 from app_private.audit_events where action like 'duinpad.actor.%' and minimal_change::text like '%token%'),'audit records do not contain claim tokens or hashes');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.duinpad_actor_admin_command('duindorp-halloween-2026','invite',jsonb_build_object('name','Synthetische Ongeverifieerde Acteur','email','duinpad-unverified@example.invalid','invitationId','b8110000-0000-4000-8000-000000000003','tokenHash',repeat('c',64)))$$,'actor invitation is independent of verified participant registration');
select set_config('request.jwt.claims','{"sub":"b8100000-0000-4000-8000-000000000003","role":"authenticated"}',true);
select throws_ok($$select api.duinpad_actor_claim('duindorp-halloween-2026',repeat('c',64))$$,'42501','NOT_AUTHORIZED','unverified email cannot activate an actor invitation');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.duinpad_actor_admin_command('duindorp-halloween-2026','invite',jsonb_build_object('name','Synthetische Verlopen Acteur','email','duinpad-other@example.invalid','invitationId','b8110000-0000-4000-8000-000000000004','tokenHash',repeat('d',64)))$$,'expired invitation fixture created');
update app_private.duinpad_actor_invitations set created_at=now()-interval '8 days',expires_at=now()-interval '1 day' where id='b8110000-0000-4000-8000-000000000004';
select set_config('request.jwt.claims','{"sub":"b8100000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select throws_ok($$select api.duinpad_actor_claim('duindorp-halloween-2026',repeat('d',64))$$,'22023','INVITATION_UNAVAILABLE','expired link cannot activate despite correct verified identity');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update app_private.email_outbox set status='processing' where dedupe_key='actor-invitation:b8110000-0000-4000-8000-000000000001';
select ok(api.worker_duinpad_actor_invitation((select id from app_private.email_outbox where dedupe_key='actor-invitation:b8110000-0000-4000-8000-000000000001')) is null,'worker refuses superseded mail even if an old lease was recovered');
select is(api.worker_mail_prepare('test','synthetic-actor-gateway-test',null,(select id from app_private.email_outbox where dedupe_key='actor-invitation:b8110000-0000-4000-8000-000000000001'),'transactional','actor_invitation','duinpad-actor@example.invalid','{}',repeat('a',64),repeat('b',64))->>'dispatch','false','gateway rechecks the recovered stale actor envelope immediately before dispatch');
insert into app_private.mail_config_versions(id,environment,version,provider,from_email,from_name,reply_to,config_hash)
 select 'b8130000-0000-4000-8000-000000000001','test',coalesce(max(version),0)+1,'resend','synthetic@example.invalid','Synthetische mail','support@example.invalid',repeat('a',64)
 from app_private.mail_config_versions where environment='test';
insert into app_private.mail_config_heads(environment,active_id) values('test','b8130000-0000-4000-8000-000000000001') on conflict(environment) do update set active_id=excluded.active_id;
update app_private.email_outbox set status='processing' where dedupe_key='actor-invitation:b8110000-0000-4000-8000-000000000003';
create temp table actor_gateway as select api.worker_mail_prepare('test','synthetic-live-actor-gateway','b8130000-0000-4000-8000-000000000001',
 (select id from app_private.email_outbox where dedupe_key='actor-invitation:b8110000-0000-4000-8000-000000000003'),'transactional','actor_invitation','duinpad-unverified@example.invalid',
 '{"html":"transient-synthetic-claim-token"}',repeat('e',64),repeat('f',64)) result;
select is((select result->>'dispatch' from actor_gateway),'true','current actor invitation can prepare through existing gateway');
select ok((select payload is null from app_private.mail_envelopes where logical_key='synthetic-live-actor-gateway'),'even gateway storage contains no plaintext actor claim link');
select ok((select payload?'material' from app_private.email_outbox where dedupe_key='actor-invitation:b8110000-0000-4000-8000-000000000003'),'only nonsecret invitation material is frozen for durable retries');
select is(api.worker_mail_prepare('test','synthetic-live-actor-gateway','b8130000-0000-4000-8000-000000000001',
 (select id from app_private.email_outbox where dedupe_key='actor-invitation:b8110000-0000-4000-8000-000000000003'),'transactional','actor_invitation','duinpad-unverified@example.invalid',null,repeat('d',64),repeat('f',64))->>'dispatch','false','changed rendering cannot reuse a prior provider idempotency key');
select * from finish();
rollback;
