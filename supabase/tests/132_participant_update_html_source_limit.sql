begin;
create extension if not exists pgtap with schema extensions;
select plan(34);

-- These fixture accounts/events exist only inside this rolled-back transaction.
insert into auth.users(id,email,email_confirmed_at) values
 ('13200000-0000-0000-0000-000000000001','updates-editor@example.invalid',now()),
 ('13200000-0000-0000-0000-000000000002','updates-walker@example.invalid',now()),
 ('13200000-0000-0000-0000-000000000003','updates-other-event@example.invalid',now());
insert into app_private.events(id,slug,title,local_date,price_cents) values
 ('13200000-0000-0000-0000-000000000011','fixture-long-updates','Synthetic long updates','2026-10-31',0),
 ('13200000-0000-0000-0000-000000000012','fixture-foreign-updates','Synthetic foreign updates','2026-10-31',0);
insert into app_private.event_capabilities(event_id,user_id,capability) values
 ('13200000-0000-0000-0000-000000000011','13200000-0000-0000-0000-000000000001','content_manage');
insert into app_private.households(id,label,primary_contact_user_id) values
 ('13200000-0000-0000-0000-000000000021','Synthetic update family','13200000-0000-0000-0000-000000000002'),
 ('13200000-0000-0000-0000-000000000022','Synthetic foreign family','13200000-0000-0000-0000-000000000003');
insert into app_private.household_members(household_id,user_id,relation_role) values
 ('13200000-0000-0000-0000-000000000021','13200000-0000-0000-0000-000000000002','owner'),
 ('13200000-0000-0000-0000-000000000022','13200000-0000-0000-0000-000000000003','owner');
insert into app_private.registrations(event_id,household_id,status,reference,submitted_at) values
 ('13200000-0000-0000-0000-000000000011','13200000-0000-0000-0000-000000000021','submitted','DPH-2026-HTML-ONE',now()),
 ('13200000-0000-0000-0000-000000000012','13200000-0000-0000-0000-000000000022','submitted','DPH-2026-HTML-OTHER',now());
insert into app_private.participant_preferences(event_id,user_id,email_updates,optional_updates_consent)
values('13200000-0000-0000-0000-000000000011','13200000-0000-0000-0000-000000000002',false,false);

create temp table update_html_results(key text primary key,value jsonb) on commit drop;
grant select,insert on update_html_results to authenticated;
insert into update_html_results select 'preferences',to_jsonb(p) from app_private.participant_preferences p
 where event_id='13200000-0000-0000-0000-000000000011' and user_id='13200000-0000-0000-0000-000000000002';
do $$begin
  perform set_config('test.update_html_body','<p>Eerste regel</p>'||E'\n'||'<p>'||repeat('x',20000-char_length('<p>Eerste regel</p>'||E'\n'||'<p></p><img src="/images/logo.webp" alt="Voorbeeld">'))||'</p><img src="/images/logo.webp" alt="Voorbeeld">',true);
end$$;

select ok(not has_function_privilege('anon','api.admin_publish_participant_update(text,text,text,text,text,boolean)','execute'),'anonymous publication remains revoked');
select ok(has_function_privilege('authenticated','api.admin_publish_participant_update(text,text,text,text,text,boolean)','execute'),'authenticated publication grant is retained');
select ok((select prosecdef and coalesce(proconfig,'{}'::text[]) @> array['search_path=""'] from pg_proc where oid='api.admin_publish_participant_update(text,text,text,text,text,boolean)'::regprocedure),'SECURITY DEFINER and empty search_path are retained');
select ok((select relrowsecurity from pg_class where oid='app_private.participant_updates'::regclass),'participant updates retain RLS');
select ok(not has_table_privilege('authenticated','app_private.participant_updates','insert'),'browser still cannot insert raw table rows');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"13200000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$insert into update_html_results values('long',api.admin_publish_participant_update('fixture-long-updates','walker','Lange bron zonder mail',current_setting('test.update_html_body'),'normal',false))$$,'exactly 20000 HTML-source characters are accepted');
select throws_ok($$select api.admin_publish_participant_update('fixture-long-updates','walker','Te lange bron',repeat('x',20001),'normal',false)$$,'22023','VALIDATION_ERROR','20001 source characters are rejected before publication');
select throws_ok($$select api.admin_publish_participant_update('fixture-long-updates','walker','Te korte bron','ab','normal',false)$$,'22023','VALIDATION_ERROR','existing minimum body length is unchanged');
select throws_ok($$select api.admin_publish_participant_update('fixture-long-updates','unknown','Ongeldige doelgroep','Testbericht','normal',false)$$,'22023','VALIDATION_ERROR','audience validation is unchanged');
select throws_ok($$select api.admin_publish_participant_update('fixture-long-updates','walker','Ongeldige prioriteit','Testbericht','unknown',false)$$,'22023','VALIDATION_ERROR','priority validation is unchanged');
select throws_ok($$select api.admin_publish_participant_update('fixture-long-updates','walker',repeat('x',121),'Testbericht','normal',false)$$,'22023','VALIDATION_ERROR','title maximum stays 120 characters');
select throws_ok($$select api.admin_publish_participant_update('fixture-foreign-updates','walker','Andere editie',current_setting('test.update_html_body'),'normal',false)$$,'42501','NOT_AUTHORIZED','content capability does not cross event boundaries');
select set_config('request.jwt.claims','{}',true);
select throws_ok($$select api.admin_publish_participant_update('fixture-long-updates','all','Zonder identiteit',current_setting('test.update_html_body'),'urgent',false)$$,'42501','NOT_AUTHORIZED','missing identity cannot publish a long or essential update');
select set_config('request.jwt.claims','{"sub":"13200000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select api.admin_publish_participant_update('fixture-long-updates','all','Onbevoegd',current_setting('test.update_html_body'),'urgent',false)$$,'42501','NOT_AUTHORIZED','ordinary participant cannot publish long messages');
set local role postgres;

select is((select char_length(body) from app_private.participant_updates where id=(select(value->>'id')::uuid from update_html_results where key='long')),20000,'database preserves all 20000 source characters');
select is((select body from app_private.participant_updates where id=(select(value->>'id')::uuid from update_html_results where key='long')),current_setting('test.update_html_body'),'HTML tags, image source and real newline survive storage without truncation');
select is((select count(*)::integer from app_private.email_outbox where payload->>'title'='Lange bron zonder mail'),0,'normal false publication queues no email');
select is((select count(*)::integer from app_private.participant_updates where event_id='13200000-0000-0000-0000-000000000011'),1,'rejected commands commit no partial updates');
select throws_ok($$update app_private.participant_updates set body=repeat('x',20001) where id=(select(value->>'id')::uuid from update_html_results where key='long')$$,'23514',null,'table constraint independently rejects oversized source');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"13200000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$insert into update_html_results values('unicode',api.admin_publish_participant_update('fixture-long-updates','walker','Unicode bron',repeat('é',20000),'normal',false))$$,'limit counts characters rather than UTF-8 bytes');
select lives_ok($$insert into update_html_results values('optional',api.admin_publish_participant_update('fixture-long-updates','walker','Optionele lange mail',current_setting('test.update_html_body'),'normal',true))$$,'normal publication still accepts send_email true');
select lives_ok($$insert into update_html_results values('important',api.admin_publish_participant_update('fixture-long-updates','walker','Belangrijke lange mail',current_setting('test.update_html_body'),'important',false))$$,'important notice still forces transactional mail despite send_email false');
select lives_ok($$insert into update_html_results values('urgent',api.admin_publish_participant_update('fixture-long-updates','walker','Urgente lange mail',current_setting('test.update_html_body'),'urgent',false))$$,'urgent notice still forces transactional mail despite send_email false');
set local role postgres;

select is((select char_length(body) from app_private.participant_updates where id=(select(value->>'id')::uuid from update_html_results where key='unicode')),20000,'multibyte source is stored completely');
select is((select count(*)::integer from app_private.email_outbox where payload->>'title'='Optionele lange mail'),0,'ordinary email still respects the opted-out preference');
select is((select count(*)::integer from app_private.email_outbox where payload->>'title'='Belangrijke lange mail'),1,'important mail reaches exactly the current event walker');
select is((select payload->>'message' from app_private.email_outbox where payload->>'title'='Belangrijke lange mail'),current_setting('test.update_html_body'),'queued payload retains the complete HTML source and newline');
select is((select count(*)::integer from app_private.email_outbox where payload->>'title'='Urgente lange mail'),1,'urgent mail retains the mandatory delivery policy');
select is((select count(*)::integer from app_private.email_outbox where payload->>'title' in('Belangrijke lange mail','Urgente lange mail') and recipient_email='updates-other-event@example.invalid'),0,'another event household is never a recipient');
select is((select payload->>'mandatoryEventNotice' from app_private.email_outbox where payload->>'title'='Belangrijke lange mail'),'true','mandatory purpose remains durable in the outbox');
select is((select to_jsonb(p) from app_private.participant_preferences p where event_id='13200000-0000-0000-0000-000000000011' and user_id='13200000-0000-0000-0000-000000000002'),(select value from update_html_results where key='preferences'),'full preference record is untouched by mandatory delivery');
select is((select minimal_change->>'audiencePolicy' from app_private.audit_events where resource_id=(select(value->>'id')::uuid from update_html_results where key='important') and action='participant.update_published'),'current_event_participants_at_publication','existing audit policy is retained');
select is((select value->>'mandatoryEventNotice' from update_html_results where key='important'),'true','command result preserves mandatory notice semantics');
select is((select(value->>'emailCount')::integer from update_html_results where key='important'),1,'command email count remains exact');

select * from finish();
rollback;
