begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table submit_case(aid uuid,iid uuid,preview jsonb,result jsonb,draft jsonb,baseline jsonb,version integer);
create function pg_temp.submit_state(_allow_submission boolean default false) returns jsonb language plpgsql as $$
declare r record; h text; result jsonb:='{}';
begin
 for r in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind='r' and (n.nspname='app_private' or (n.nspname='auth' and c.relname in ('users','identities','sessions')))
  and not (_allow_submission and c.relname in ('portal_applications','email_outbox','audit_events','command_receipts')) order by n.nspname,c.relname loop
  execute format('select md5(coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text)::text,'''') ) from %I.%I t',r.nspname,r.relname) into h;
  result:=result||jsonb_build_object(r.nspname||'.'||r.relname,h);
 end loop;
 return result;
end $$;

-- Deliberately fictional, isolated fixture. No production P-42 identifier is used.
select api.portal_registration_begin('duindorp-halloween-2026','parent-size-5@example.invalid','Fictieve indienproef','0612345678','','','','',repeat('a',64));
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
insert into submit_case(aid) select (api.portal_registration_claim('duindorp-halloween-2026')->>'id')::uuid;
update submit_case set iid=(select id from app_private.portal_registration_intakes where application_id=aid);
select api.portal_application_save('duindorp-halloween-2026','{"contactName":"Fictieve indienproef","phone":"0612345678","requestedWorldSlug":"heksenrijk","intensity":"2","warnings":{},"availableFrom":"17:00","availableUntil":"21:00","availability":false,"locationConsent":false}',(select version from app_private.portal_applications where id=(select aid from submit_case)));
update submit_case set draft=(select private_draft_data from app_private.portal_applications where id=aid),version=(select a.version from app_private.portal_applications a where a.id=aid);

select ok(not has_function_privilege('anon','api.admin_portal_application_submit_preview(text,uuid)','execute'),'anonymous users cannot preview private submissions');
select ok(not has_function_privilege('anon','api.admin_portal_application_submit(text,uuid,integer,text,text,text)','execute'),'anonymous users cannot submit');
select ok(not has_function_privilege('authenticated','app_private.portal_submission_validation(uuid,jsonb,text)','execute'),'private validator is not an exposed bypass');
select throws_ok($$select api.admin_portal_application_submit_preview('duindorp-halloween-2026',aid) from submit_case$$,'42501','NOT_AUTHORIZED','ordinary applicant cannot use the admin path');
select throws_ok($$select api.admin_portal_application_submit('duindorp-halloween-2026',aid,version,repeat('0',64),'Bewoner vroeg de organisatie om indiening','unauthorized-submit-093') from submit_case$$,'42501','NOT_AUTHORIZED','ordinary applicant cannot apply the organization command');
insert into app_private.event_capabilities(event_id,user_id,capability) select id,'a0000000-0000-0000-0000-000000000005','event_admin' from app_private.events where slug='duindorp-halloween-2026';
select throws_ok($$select api.admin_portal_application_submit_preview('duindorp-halloween-2026',aid) from submit_case$$,'42501','NOT_AUTHORIZED','event_admin alone does not imply portals_manage');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update submit_case set baseline=pg_temp.submit_state();
update submit_case set preview=api.admin_portal_application_submit_preview('duindorp-halloween-2026',aid);
select is(pg_temp.submit_state(),(select baseline from submit_case),'preview and cancellation have zero domain, audit, outbox or identity writes');
select is((select preview->>'allowed' from submit_case),'true','relaxed submit accepts missing address, portal name, description and unconfirmed consents');
select is((select jsonb_array_length(preview->'missingFields') from submit_case),0,'approval-only fields are not missing submit fields');
select is((select jsonb_array_length(preview->'approvalRequirements') from submit_case),1,'only missing address is an additional requirement under the current approval policy');
select is((select preview#>>'{contact,email}' from submit_case),'parent-size-5@example.invalid','canonical recipient comes from the actual verified applicant');
select is((select preview#>>'{consent,locationConsent}' from submit_case),'false','preview reports actual consent without inventing agreement');
select ok((select not (preview ? 'private_draft_data' or preview ? 'raw_user_meta_data' or preview ? 'encrypted_password') from submit_case),'preview is a safe DTO');
select throws_ok($$select api.admin_portal_application_submit_preview('missing-event',aid) from submit_case$$,'42501','NOT_AUTHORIZED','unknown event cannot be used');
select throws_ok($$select api.admin_portal_application_submit_preview('duindorp-halloween-2026','12000000-0000-0000-0000-000000000029')$$,'42501','NOT_AUTHORIZED','a manual portal is not silently converted into an application');

-- A real other event, with permission in both, still cannot address this application.
insert into app_private.events select (jsonb_populate_record(null::app_private.events,to_jsonb(e)||'{"id":"10000000-0000-0000-0000-000000000093","slug":"fictitious-other-submit-event"}'::jsonb)).* from app_private.events e where slug='duindorp-halloween-2026';
insert into app_private.event_capabilities(event_id,user_id,capability) values('10000000-0000-0000-0000-000000000093','f0000000-0000-0000-0000-000000000001','portals_manage');
select throws_ok($$select api.admin_portal_application_submit_preview('fictitious-other-submit-event',aid) from submit_case$$,'42501','NOT_AUTHORIZED','cross-event application lookup is rejected even with both permissions');
select throws_ok($$select api.admin_portal_application_submit('fictitious-other-submit-event',aid,version,repeat('0',64),'Bewoner vroeg de organisatie om indiening','cross-event-submit-093') from submit_case$$,'42501','NOT_AUTHORIZED','cross-event apply is rejected even with both permissions');

-- Stale previews bind actual draft, identity, intake and portal context.
update app_private.portal_applications set private_draft_data=private_draft_data-'phone',version=version+1 where id=(select aid from submit_case);
select throws_ok($$select api.admin_portal_application_submit('duindorp-halloween-2026',aid,version,preview->>'inputHash','Bewoner vroeg de organisatie om indiening','stale-draft-preview-093') from submit_case$$,'40001','STALE_SUBMISSION_PREVIEW','changed draft/version cannot pass an old preview');
update submit_case set preview=api.admin_portal_application_submit_preview('duindorp-halloween-2026',aid),version=(select a.version from app_private.portal_applications a where a.id=aid);
select ok((select exists(select 1 from jsonb_array_elements(preview->'missingFields') f where f->>'field'='phone') from submit_case),'missing telephone is a concrete repairable blocker');
select throws_ok($$select api.admin_portal_application_submit('duindorp-halloween-2026',aid,version,preview->>'inputHash','Bewoner vroeg de organisatie om indiening','missing-phone-command-093') from submit_case$$,'23514','SUBMISSION_BLOCKED','current preview cannot override missing submit data');
update app_private.portal_applications set private_draft_data=(select draft from submit_case),version=version+1 where id=(select aid from submit_case);

create temp table bad_times(value text);
insert into bad_times values('99:00'),(''),('12:7'),('21:00');
select ok(exists(select 1 from jsonb_array_elements(app_private.portal_submission_validation(a.event_id,a.private_draft_data||jsonb_build_object('availableFrom',bad_times.value),'parent-size-5@example.invalid')->'missingFields') f where f->>'field' in ('availableFrom','openingTimes')),'invalid or non-increasing opening times are blocked: '||bad_times.value)
from bad_times cross join app_private.portal_applications a where a.id=(select aid from submit_case);

update app_private.portal_applications set private_draft_data=jsonb_set(private_draft_data,'{email}','"someone-else@example.invalid"') where id=(select aid from submit_case);
select is(api.admin_portal_application_submit_preview('duindorp-halloween-2026',(select aid from submit_case))->>'allowed','false','mismatched draft identity is not silently repaired');
update app_private.portal_applications set private_draft_data=(select draft from submit_case) where id=(select aid from submit_case);
create temp table original_confirmation as select id,email_confirmed_at from auth.users where id='a0000000-0000-0000-0000-000000000005';
update auth.users set email_confirmed_at=null where id='a0000000-0000-0000-0000-000000000005';
select is(api.admin_portal_application_submit_preview('duindorp-halloween-2026',(select aid from submit_case))->>'allowed','false','unconfirmed applicant must complete verification');
update auth.users u set email_confirmed_at=o.email_confirmed_at from original_confirmation o where o.id=u.id;
update submit_case set preview=api.admin_portal_application_submit_preview('duindorp-halloween-2026',aid),version=(select a.version from app_private.portal_applications a where a.id=aid);
update app_private.portal_registration_intakes set version=version+1 where id=(select iid from submit_case);
select throws_ok($$select api.admin_portal_application_submit('duindorp-halloween-2026',aid,version,preview->>'inputHash','Bewoner vroeg de organisatie om indiening','stale-intake-preview-093') from submit_case$$,'40001','STALE_SUBMISSION_PREVIEW','intake changes bind the preview independently of application version');
update app_private.portal_registration_intakes set withdrawn_at=now() where id=(select iid from submit_case);
select is(api.admin_portal_application_submit_preview('duindorp-halloween-2026',(select aid from submit_case))->>'allowed','false','withdrawn intake stays blocked');
update app_private.portal_registration_intakes set withdrawn_at=null,claimed_user_id='b0000000-0000-0000-0000-000000000001' where id=(select iid from submit_case);
select is(api.admin_portal_application_submit_preview('duindorp-halloween-2026',(select aid from submit_case))->>'allowed','false','intake claimed by another identity stays blocked');
update app_private.portal_registration_intakes set claimed_user_id='a0000000-0000-0000-0000-000000000005' where id=(select iid from submit_case);

update app_private.portal_applications set review_status='rejected' where id=(select aid from submit_case);
select is(api.admin_portal_application_submit_preview('duindorp-halloween-2026',(select aid from submit_case))->>'allowed','false','rejected application stays blocked');
update app_private.portal_applications set review_status='withdrawn' where id=(select aid from submit_case);
select is(api.admin_portal_application_submit_preview('duindorp-halloween-2026',(select aid from submit_case))->>'allowed','false','withdrawn application stays blocked');
update app_private.portal_applications set review_status='approved' where id=(select aid from submit_case);
select is(api.admin_portal_application_submit_preview('duindorp-halloween-2026',(select aid from submit_case))->>'allowed','false','approved application stays blocked');
update app_private.portal_applications set review_status='draft' where id=(select aid from submit_case);

create temp table original_portal_context as select id,application_id,lifecycle_status,version from app_private.portals where id='12000000-0000-0000-0000-000000000029';
update app_private.portals set application_id=(select aid from submit_case),lifecycle_status='archived' where id=(select id from original_portal_context);
select is(api.admin_portal_application_submit_preview('duindorp-halloween-2026',(select aid from submit_case))->>'allowed','false','an archived linked operational portal blocks submission');
update app_private.portals set lifecycle_status='approved' where id=(select id from original_portal_context);
update submit_case set preview=api.admin_portal_application_submit_preview('duindorp-halloween-2026',aid),version=(select a.version from app_private.portal_applications a where a.id=aid);
update app_private.portals set version=version+1 where id=(select id from original_portal_context);
select throws_ok($$select api.admin_portal_application_submit('duindorp-halloween-2026',aid,version,preview->>'inputHash','Bewoner vroeg de organisatie om indiening','stale-linked-portal-093') from submit_case$$,'40001','STALE_SUBMISSION_PREVIEW','linked portal version independently binds the submission preview');
update app_private.portals p set application_id=o.application_id,lifecycle_status=o.lifecycle_status,version=o.version from original_portal_context o where p.id=o.id;
update app_private.portal_applications set review_status='changes_requested' where id=(select aid from submit_case);
select is(api.admin_portal_application_submit_preview('duindorp-halloween-2026',(select aid from submit_case))->>'allowed','true','changes requested can be deliberately resubmitted');
update app_private.portal_applications set review_status='draft' where id=(select aid from submit_case);

-- Only the intentionally permitted application fields and command records may change.
update submit_case set preview=api.admin_portal_application_submit_preview('duindorp-halloween-2026',aid),baseline=pg_temp.submit_state(true),version=(select a.version from app_private.portal_applications a where a.id=aid);
select throws_ok($$select api.admin_portal_application_submit('duindorp-halloween-2026',aid,version,preview->>'inputHash','kort','reason-too-short-key-093') from submit_case$$,'22023','INVALID_INPUT','reason is mandatory');
select throws_ok($$select api.admin_portal_application_submit('duindorp-halloween-2026',aid,version,preview->>'inputHash',repeat('x',501),'reason-too-long-key-093') from submit_case$$,'22023','INVALID_INPUT','reason is limited to 500 characters');
update submit_case set result=api.admin_portal_application_submit('duindorp-halloween-2026',aid,version,preview->>'inputHash','Bewoner vroeg de organisatie om indiening','actual-submit-receipt-093');
select is((select review_status::text from app_private.portal_applications where id=(select aid from submit_case)),'submitted','admin command only submits, without approval');
select is((select a.version from app_private.portal_applications a where a.id=(select aid from submit_case)),(select version+1 from submit_case),'submission increments exactly one version');
select ok((select submitted_at is not null and reviewed_by is null and reviewed_at is null and review_feedback is null from app_private.portal_applications where id=(select aid from submit_case)),'submission sets the correct workflow metadata');
select is((select private_draft_data from app_private.portal_applications where id=(select aid from submit_case)),(select draft from submit_case),'all draft and consent values are preserved exactly');
select is(pg_temp.submit_state(true),(select baseline from submit_case),'all other domain tables, memberships, ownership, auth metadata, children, payments, routes and passports are unchanged');
select is((select applicant_user_id::text from app_private.portal_applications where id=(select aid from submit_case)),'a0000000-0000-0000-0000-000000000005','applicant remains the actual resident');
select is((select count(*) from app_private.portals where application_id=(select aid from submit_case)),0::bigint,'submission creates no operational portal or ownership');
select is((select count(*) from app_private.email_outbox where message_type='portal_received' and payload->>'applicationId'=(select aid::text from submit_case)),1::bigint,'exactly one semantic receipt message is enqueued');
select ok((select recipient_ref='a0000000-0000-0000-0000-000000000005' and recipient_email='parent-size-5@example.invalid' from app_private.email_outbox where message_type='portal_received' and payload->>'applicationId'=(select aid::text from submit_case)),'mail is addressed to the verified resident, never the actor');
select ok((select actor_id='f0000000-0000-0000-0000-000000000001' and minimal_change->>'onBehalfOfResident'='true' and length(minimal_change->>'reason')>=10 from app_private.audit_events where resource_id=(select aid from submit_case) and action='portal_application.submitted_by_organization'),'dedicated audit preserves the actual manager and reason');
select ok(exists(select 1 from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026')->'registrations') r cross join lateral jsonb_array_elements(r->'timeline') t where r->>'applicationId'=(select aid::text from submit_case) and t->>'label'='Namens bewoner ingediend door organisatie'),'timeline distinguishes organization submission from a resident action');
select is((select api.admin_portal_application_submit('duindorp-halloween-2026',aid,version,preview->>'inputHash','Bewoner vroeg de organisatie om indiening','actual-submit-receipt-093') from submit_case),(select result from submit_case),'exact retry returns the original receipt before stale version rejection');
select throws_ok($$select api.admin_portal_application_submit('duindorp-halloween-2026',aid,version,preview->>'inputHash','Dit is bewust een andere opdracht','actual-submit-receipt-093') from submit_case$$,'23505','IDEMPOTENCY_CONFLICT','same key with different payload is a conflict');
select throws_ok($$select api.admin_portal_application_submit('duindorp-halloween-2026',aid,version,preview->>'inputHash','Bewoner vroeg de organisatie om indiening','independent-second-submit-093') from submit_case$$,'40001','STALE_SUBMISSION_PREVIEW','another command cannot submit the old version again');
select is((select count(*) from app_private.email_outbox where message_type='portal_received' and payload->>'applicationId'=(select aid::text from submit_case)),1::bigint,'replays and rejected commands do not duplicate mail');
select is((select count(*) from app_private.audit_events where resource_id=(select aid from submit_case) and action='portal_application.submitted_by_organization'),1::bigint,'replays do not duplicate audit');
update auth.users set email_confirmed_at=null where id='a0000000-0000-0000-0000-000000000005';
select throws_ok($$select api.admin_portal_application_submit('duindorp-halloween-2026',aid,version,preview->>'inputHash','Bewoner vroeg de organisatie om indiening','actual-submit-receipt-093') from submit_case$$,'23514','SUBMISSION_REPLAY_CONTEXT_CHANGED','receipt replay still rechecks the current verified resident context');
update auth.users u set email_confirmed_at=o.email_confirmed_at from original_confirmation o where o.id=u.id;
select throws_ok($$select api.admin_review_portal_application(aid,(result->>'version')::integer,'approved','heksenrijk',null,null,'Afzonderlijke goedkeuringscontrole') from submit_case$$,'23514','CONTACT_ADDRESS_REQUIRED','approval still requires the complete address that submission may omit');
update app_private.event_capabilities set revoked_at=now() where user_id='f0000000-0000-0000-0000-000000000001' and capability='portals_manage' and event_id=(select event_id from app_private.portal_applications where id=(select aid from submit_case)) and revoked_at is null;
select throws_ok($$select api.admin_portal_application_submit('duindorp-halloween-2026',aid,version,preview->>'inputHash','Bewoner vroeg de organisatie om indiening','actual-submit-receipt-093') from submit_case$$,'42501','NOT_AUTHORIZED','revoked permission also blocks receipt replay');

-- The resident path retains its own auth.uid, relaxed validation and recipient policy.
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
update app_private.portal_applications set review_status='changes_requested',version=version+1 where id=(select aid from submit_case);
select lives_ok($$select api.portal_application_submit(aid,(select a.version from app_private.portal_applications a where a.id=aid),'resident-relaxed-submit-093','resident-request-hash-093') from submit_case$$,'legitimate resident resubmission retains the same relaxed validation');
select is((select actor_id::text from app_private.audit_events where resource_id=(select aid from submit_case) and action='portal_application.submitted' order by id desc limit 1),'a0000000-0000-0000-0000-000000000005','resident submission is not mislabeled as organization activity');
select * from finish();
rollback;
