begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);

select ok(not has_function_privilege('authenticated','api.worker_registration_management_mail_payload(uuid)','execute'),'a parent cannot read another family mail material');
select ok(not has_function_privilege('anon','api.worker_registration_activation_mail_payload(uuid)','execute'),'an anonymous client cannot obtain invitation tokens');
select ok(has_function_privilege('service_role','api.worker_registration_management_mail_payload(uuid)','execute'),'the existing mail worker can resolve family changes');
select ok(not has_function_privilege('service_role','app_private.worker_mail_prepare_before_registration_management(text,text,uuid,uuid,text,text,text,jsonb,text,text)','execute'),'the service cannot call the unguarded old gateway directly');

create temp table mail_case as select api.admin_registration_create(e.slug,jsonb_build_object(
 'parentName','Synthetische Mailouder','email','registration-mail-guard@example.invalid',
 'preferredStartAt',app_private.exact_preference_options(e.id)->'allowedStartTimes'->>0,
 'desiredEndAt',app_private.exact_preference_options(e.id)->'allowedEndTimes'->>0,
 'children',jsonb_build_array(jsonb_build_object('name','Synthetisch Kind','age',8))),
 e.settings_version,'b9010000-0000-0000-0000-000000000001','Synthetische uitnodiging voor gatewayvalidatie') result
 from app_private.events e where slug='duindorp-halloween-2026';
alter table mail_case add column outbox_id uuid;
alter table mail_case add column material jsonb;
update mail_case set outbox_id=(select id from app_private.email_outbox where payload->>'registrationId'=result->>'registrationId' and message_type='registration_activation');
update app_private.email_outbox set status='processing' where id=(select outbox_id from mail_case);
update mail_case set material=api.worker_registration_activation_mail_payload(outbox_id);
select matches((select material->>'registrationBindingHash' from mail_case),'^[a-f0-9]{64}$','worker adds a bounded opaque invitation binding');
select ok(not((select material from mail_case)?'recipientEmail'),'mail material does not turn contact email into public display data');

insert into app_private.mail_config_versions(id,environment,version,provider,from_email,from_name,reply_to,config_hash)
 select 'b9010000-0000-0000-0000-000000000010','test',coalesce(max(version),0)+1,'resend','synthetic@example.invalid','Synthetic local mail','support@example.invalid',repeat('a',64)
 from app_private.mail_config_versions where environment='test';
insert into app_private.mail_config_heads(environment,active_id) values('test','b9010000-0000-0000-0000-000000000010')
 on conflict(environment) do update set active_id=excluded.active_id;
create function pg_temp.prepare_registration_mail(_binding text,_recipient text default 'registration-mail-guard@example.invalid') returns jsonb language sql as $$
 select api.worker_mail_prepare('test','mail/'||outbox_id||'/1','b9010000-0000-0000-0000-000000000010',outbox_id,'transactional','registration_activation',_recipient,
  jsonb_build_object('subject','Synthetische uitnodiging','text','Synthetische tekst','tags',jsonb_build_array(jsonb_build_object('name','registration_binding','value',_binding))),repeat('c',64),repeat('d',64)) from mail_case
$$;
select is(pg_temp.prepare_registration_mail(repeat('b',64))->>'error_code','REGISTRATION_MATERIAL_CHANGED','a stale renderer is deferred before creating an envelope');
select is((select count(*)::integer from app_private.mail_envelopes where outbox_id=(select outbox_id from mail_case)),0,'stale rendering creates no provider attempt');
select is(pg_temp.prepare_registration_mail((select material->>'registrationBindingHash' from mail_case),'wrong@example.invalid')->>'error_code','REGISTRATION_MAIL_SUPERSEDED','wrong recipient fails the gateway recheck');
select is(pg_temp.prepare_registration_mail((select material->>'registrationBindingHash' from mail_case))->>'dispatch','true','the current invitation may prepare one durable envelope');
select is((select count(*)::integer from app_private.mail_envelopes where outbox_id=(select outbox_id from mail_case)),1,'one envelope is stored for the invitation');

select lives_ok($$select api.admin_registration_invite('duindorp-halloween-2026',(result->>'registrationId')::uuid,
 (select version from app_private.registrations where id=(result->>'registrationId')::uuid),'corrected-registration-mail@example.invalid',
 'b9010000-0000-0000-0000-000000000002','Synthetische correctie voor eerste ouderclaim') from mail_case$$,'an authorized correction rotates the pending invitation');
select ok((select api.worker_registration_activation_mail_payload(outbox_id) is null from mail_case),'the old invitation becomes unavailable after email correction');
select is(pg_temp.prepare_registration_mail((select material->>'registrationBindingHash' from mail_case))->>'dispatch','false','an existing retry envelope cannot bypass the revoked invitation');
select is((select status from app_private.mail_envelopes where outbox_id=(select outbox_id from mail_case)),'reconcile','a prior attempted envelope remains auditable instead of being resent');
select is((select count(*)::integer from app_private.registration_children where registration_id=(select (result->>'registrationId')::uuid from mail_case)),1,'revoking a link preserves the durable child identity');
update app_private.mail_envelopes set status='accepted',provider_id='synthetic-already-accepted' where outbox_id=(select outbox_id from mail_case);
select is(pg_temp.prepare_registration_mail((select material->>'registrationBindingHash' from mail_case))->>'dispatch','false','historical provider acceptance never dispatches again');
select is(pg_temp.prepare_registration_mail((select material->>'registrationBindingHash' from mail_case))->>'status','accepted','existing provider acceptance remains a fact after a later family change');

\ir helpers/registration-management.inc
select pg_temp.registration_management_fixture();
-- An independent leader role remains authorized; the
-- household nevertheless defaults to the destination group after its move.
insert into app_private.walking_groups(id,event_id,code,status) select 'b9010000-0000-0000-0000-000000000099',id,'SYNTHETIC-INDEPENDENT','draft'
 from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.group_leaders(group_id,user_id,active_from,revision,assigned_by)
 select 'b9010000-0000-0000-0000-000000000099',h.primary_contact_user_id,'2026-01-01Z',1,'f0000000-0000-0000-0000-000000000001'
 from app_private.households h join app_private.registrations r on r.household_id=h.id where r.id='22000000-0000-0000-0000-000000000001';
select lives_ok($$select api.admin_registration_manage_apply('duindorp-halloween-2026','22000000-0000-0000-0000-000000000001','move',
 jsonb_build_object('targetGroupId','23000000-0000-0000-0000-000000000002'),
 api.admin_registration_management_preview('duindorp-halloween-2026','22000000-0000-0000-0000-000000000001')->>'inputHash',
 'Synthetische gezinsverplaatsing met onafhankelijke leidersrol','b9010000-0000-0000-0000-000000000003')$$,'a supported family move retains an independent leader role');
select set_config('request.jwt.claims',jsonb_build_object('sub',(select h.primary_contact_user_id from app_private.households h join app_private.registrations r on r.household_id=h.id where r.id='22000000-0000-0000-0000-000000000001'),'role','authenticated')::text,true);
select is((select role->>'groupId' from jsonb_array_elements(api.participant_context('duindorp-halloween-2026')->'roles') role where role->>'key'='walker'),
 '23000000-0000-0000-0000-000000000002','the participant environment follows the moved household rather than a separate old leader role');
select ok(app_private.is_current_leader('b9010000-0000-0000-0000-000000000099',auth.uid()),'an independently authorized leader role is preserved');
select * from finish();
rollback;
