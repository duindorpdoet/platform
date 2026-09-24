begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temporary table batch_test (
  selection jsonb, result jsonb, confirmed jsonb,
  first_payment uuid, second_payment uuid, first_registration uuid, second_registration uuid
) on commit drop;
grant select, update on batch_test to authenticated;
insert into batch_test(first_payment, second_payment, first_registration, second_registration)
select p1.id, p2.id, p1.registration_id, p2.registration_id
from app_private.payment_requests p1 cross join app_private.payment_requests p2
where p1.reference = 'PAY-FIXTURE-1' and p2.reference = 'PAY-FIXTURE-5';
delete from app_private.payment_entries where request_id in (select first_payment from batch_test union all select second_payment from batch_test);
update app_private.payment_requests set status = 'awaiting_link', external_url = null, version = 1
where id in (select first_payment from batch_test union all select second_payment from batch_test);
-- A second adult belonging to both households must receive just one batch e-mail.
insert into app_private.household_members(household_id,user_id,relation_role)
select household_id,'a0000000-0000-0000-0000-000000000001','adult'
from app_private.registrations where id = (select second_registration from batch_test)
on conflict do nothing;
update batch_test set selection = jsonb_build_array(jsonb_build_object('id',first_payment,'version',1),jsonb_build_object('id',second_payment,'version',1));

select ok(not has_function_privilege('anon','api.admin_payment_batch_publish(text,jsonb,text,text,text,uuid)','execute'), 'anonymous visitors cannot publish shared payment links');
select ok(not has_table_privilege('authenticated','app_private.payment_link_batches','insert'), 'participants cannot insert batches directly');
select ok(not has_table_privilege('authenticated','app_private.payment_link_batch_members','insert'), 'participants cannot add members directly');
select ok(not has_table_privilege('anon','app_private.payment_link_batches','select'), 'anonymous visitors cannot enumerate private batch links');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$ select api.admin_payment_batch_publish('duindorp-halloween-2026',(select selection from batch_test),'https://tikkie.me/pay/shared-test','Gezamenlijke betaling','batch-test-publish') $$,
  '42501','NOT_AUTHORIZED','a parent cannot publish a shared payment request');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$ select api.admin_payment_batch_publish('duindorp-halloween-2026',(select selection from batch_test),'https://tikkie.me.attacker.invalid/pay/test','Gezamenlijke betaling','batch-invalid-url') $$,
  '22023','VALIDATION_ERROR','an impostor Tikkie host is rejected');
select throws_ok($$ select api.admin_payment_batch_publish('duindorp-halloween-2026',(select selection from batch_test),'https://tikkie.me:443/pay/test','Gezamenlijke betaling','batch-invalid-port') $$,
  '22023','VALIDATION_ERROR','an explicit port in the payment URL is rejected');
select throws_ok($$ select api.admin_payment_batch_publish('duindorp-halloween-2026',(select jsonb_build_array(selection->0,selection->0) from batch_test),'https://tikkie.me/pay/shared-test','Gezamenlijke betaling','batch-duplicate-selection') $$,
  '22023','VALIDATION_ERROR','duplicate request selections cannot inflate a batch total');
select throws_ok($$ select api.admin_payment_batch_publish('duindorp-halloween-2026',(select jsonb_set(selection,'{1,version}','999') from batch_test),'https://tikkie.me/pay/shared-test','Gezamenlijke betaling','batch-stale-selection') $$,
  '40001','STALE_VERSION','one stale selected payment rejects the entire batch');
reset role;
select is((select count(*)::integer from app_private.payment_requests where payment_batch_id is not null and id in (select first_payment from batch_test union all select second_payment from batch_test)),0,'a failed batch leaves neither selected request linked');
select is((select count(*)::integer from app_private.email_outbox where message_type='payment_link_ready' and payload->>'externalUrl'='https://tikkie.me/pay/shared-test'),0,'a failed batch queues no payment e-mail');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$ update batch_test set result=api.admin_payment_batch_publish('duindorp-halloween-2026',selection,'https://tikkie.me/pay/shared-test','Gezamenlijke betaling','batch-test-publish') $$,
  'the manager publishes one shared Tikkie for two households');
select is((select (result->>'totalAmountCents')::integer from batch_test),1200,'the batch amount is the sum of both original invoices');
select is((select jsonb_array_length(result->'participants') from batch_test),2,'the batch describes both linked households');
select is((select result->>'payerPaymentRequestId' from batch_test),(select first_payment::text from batch_test),'the first selected household is the default single payer');
select is(api.admin_payment_batch_publish('duindorp-halloween-2026',(select selection from batch_test),'https://tikkie.me/pay/shared-test','Gezamenlijke betaling','batch-test-publish'),
  (select result from batch_test),'replaying the publication command returns the original batch');
select throws_ok($$ select api.admin_payment_batch_publish('duindorp-halloween-2026',(select selection from batch_test),'https://tikkie.me/pay/another','Gezamenlijke betaling','batch-test-publish') $$,
  '23505','IDEMPOTENCY_CONFLICT','the same publication key cannot silently change the payment URL');
select ok((select item ? 'parentName' and item ? 'parentEmail' and item ? 'householdLabel' and item ? 'groupCode' and item ? 'groupName' and item ? 'batch'
  from jsonb_array_elements(api.admin_payments_snapshot('duindorp-halloween-2026')) item where item->>'id'=(select first_payment::text from batch_test)),
  'admin payment cards identify the parent, household, group and shared batch');
reset role;
select is((select count(*)::integer from app_private.payment_link_batch_members where batch_id=(select (result->>'id')::uuid from batch_test)),2,'the batch contains both invoices exactly once');
select is((select count(*)::integer from app_private.email_outbox where message_type='payment_link_ready' and payload->>'externalUrl'='https://tikkie.me/pay/shared-test'),1,'only the designated payer household receives the direct Tikkie e-mail');
select is((select recipient_email from app_private.email_outbox where message_type='payment_link_ready' and payload->>'externalUrl'='https://tikkie.me/pay/shared-test'),'parent-a@example.invalid','the designated payer receives the direct link, not every linked family');
select ok((select bool_and(payload ? 'batchId' and payload ? 'batchVersion' and nullif(payload->>'payerName','') is not null) from app_private.email_outbox where message_type='payment_link_ready' and payload->>'externalUrl'='https://tikkie.me/pay/shared-test'),'the payment mail includes payer and batch revision metadata');
select ok((select bool_and((payload->>'amountCents')::integer=1200 and jsonb_array_length(payload->'paymentParticipants')=2)
  from app_private.email_outbox where message_type='payment_link_ready' and payload->>'externalUrl'='https://tikkie.me/pay/shared-test'),
  'every batch e-mail contains the full joint total and both names');
update batch_test set selection=(select jsonb_agg(jsonb_build_object('id',id,'version',version) order by case when id=(select first_payment from batch_test) then 0 else 1 end) from app_private.payment_requests
  where id in (select first_payment from batch_test union all select second_payment from batch_test));
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$ select api.admin_payment_batch_publish('duindorp-halloween-2026',(select selection from batch_test),'https://tikkie.me/pay/shared-test','Zelfde betaalverzoek','batch-test-noop') $$,
  'the same current members and URL can be submitted again safely');
select throws_ok($$ select api.admin_payment_batch_publish('duindorp-halloween-2026',(select selection from batch_test),'https://tikkie.me/pay/noop-changed','Zelfde betaalverzoek','batch-test-noop') $$,
  '23505','IDEMPOTENCY_CONFLICT','even an unchanged publication reserves its idempotency key');
select throws_ok($$ select api.admin_payment_batch_publish('duindorp-halloween-2026',(select jsonb_build_array(selection->0) from batch_test),'https://tikkie.me/pay/subset','Onvolledige selectie','batch-test-subset') $$,
  '23514','BATCH_MEMBERSHIP_MISMATCH','an existing batch cannot be edited through only one family invoice');
reset role;
select is((select count(*)::integer from app_private.email_outbox where message_type='payment_link_ready' and payload->>'externalUrl'='https://tikkie.me/pay/shared-test'),1,'resubmitting the unchanged batch does not queue duplicate mail');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select ok(nullif(api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,payment,externalUrl}','') is null,'a non-paying linked household does not receive the active Tikkie link');
select is(api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,payment,batch,canPay}','false','the linked non-payer has no active payment action');
select ok(nullif(api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,payment,batch,externalUrl}','') is null,'the nested batch projection cannot leak the payer-only link');
select throws_ok($$ select api.registration_report_payment((select second_registration from batch_test),2) $$,
  '42501','NOT_AUTHORIZED','a linked non-payer cannot report payment for the whole batch');
select throws_ok($$ select api.admin_payment_batch_confirm((select (result->>'id')::uuid from batch_test),1,1200,'PARENT-CLAIM','Ouder kan niet zelf bevestigen','batch-parent-confirm') $$,
  '42501','NOT_AUTHORIZED','a linked parent cannot confirm their own shared payment');
select throws_ok($$ select api.admin_payment_batch_cancel((select (result->>'id')::uuid from batch_test),1,'Ouder kan niet zelf intrekken') $$,
  '42501','NOT_AUTHORIZED','a linked parent cannot withdraw the shared payment for everyone');
select is((api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,payment,batch,totalAmountCents}')::integer,1200,'the parent dashboard shows the joint amount instead of suggesting their individual share is the total');
select is(jsonb_array_length(api.registration_snapshot('duindorp-halloween-2026') #> '{registration,payment,batch,participants}'),2,'the parent dashboard identifies both households paying together');
select ok((api.registration_snapshot('duindorp-halloween-2026') #> '{registration,payment,batch}')::text not like '%@example.invalid%','the shared parent projection does not disclose other parents e-mail addresses');
select throws_ok($$ select api.admin_payment_batch_publish('duindorp-halloween-2026',(select selection from batch_test),'https://tikkie.me/pay/shared-test','Gezamenlijke betaling','batch-test-publish') $$,
  '42501','NOT_AUTHORIZED','a different actor cannot exploit the manager publication idempotency key');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000007","role":"authenticated"}',true);
select ok(api.registration_snapshot('duindorp-halloween-2026')::text not like '%https://tikkie.me/pay/shared-test%','another household cannot see the private shared payment link');
select ok(coalesce(api.registration_snapshot('duindorp-halloween-2026') #> '{registration,payment,batch}','null'::jsonb)='null'::jsonb,'another household cannot see the batch participant names');

select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$ select api.payment_set_external_link((select first_payment from batch_test),(select (selection->0->>'version')::integer from batch_test),'https://tikkie.me/pay/individual','Mag de gezamenlijke link niet vervangen') $$,
  '23514','SHARED_PAYMENT_REQUIRES_BATCH','individual link edits cannot replace a shared payment');
select throws_ok($$ select api.payment_confirm_versioned((select first_payment from batch_test),2,200,'INDIVIDUAL-SHARED','Geen losse boeking','batch-individual','batch-individual-hash') $$,
  '23514','SHARED_PAYMENT_REQUIRES_BATCH','individual confirmation cannot partially settle a shared payment');
select throws_ok($$ select api.admin_payment_batch_confirm((select (result->>'id')::uuid from batch_test),(select (result->>'version')::integer from batch_test),200,'SHARED-WRONG-TOTAL','Onvolledig bedrag','batch-wrong-total') $$,
  '23514','BATCH_AMOUNT_MISMATCH','the joint batch cannot be confirmed using only one family share');
select throws_ok($$ select api.admin_payment_batch_confirm((select (result->>'id')::uuid from batch_test),999,1200,'SHARED-STALE','Verouderd scherm','batch-stale-confirm') $$,
  '40001','STALE_VERSION','a stale shared confirmation cannot write ledger entries');
select throws_ok($$ select api.admin_payment_batch_confirm((select (result->>'id')::uuid from batch_test),null,1200,'SHARED-NULL','Geen revisie meegegeven','batch-null-confirm') $$,
  '40001','STALE_VERSION','a null revision cannot bypass confirmation concurrency protection');
select throws_ok($$ select api.admin_payment_batch_cancel((select (result->>'id')::uuid from batch_test),null,'Geen revisie meegegeven') $$,
  '40001','STALE_VERSION','a null revision cannot bypass cancellation concurrency protection');
reset role;
delete from app_private.household_members where user_id='a0000000-0000-0000-0000-000000000001' and household_id=(select household_id from app_private.registrations where id=(select second_registration from batch_test));
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,payment,externalUrl}','https://tikkie.me/pay/shared-test','the designated payer receives the active Tikkie URL');
select is(api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,payment,batch,canPay}','true','the payer sees an active payment action');
select throws_ok($$ select api.registration_report_payment((select first_registration from batch_test),null) $$,
  '40001','STALE_VERSION','a null version cannot bypass the payer report revision guard');
select lives_ok($$ select api.registration_report_payment((select first_registration from batch_test),2) $$,'a household can report the one shared payment');
reset role;
select is((select count(*)::integer from app_private.payment_requests where id in (select first_payment from batch_test union all select second_payment from batch_test) and status='reported'),2,'a shared report marks both requests reported without confirmation');
select is((select count(*)::integer from app_private.payment_entries where amount_cents<>0 and request_id in (select first_payment from batch_test union all select second_payment from batch_test)),0,'a household report never books money');
-- Reporting may advance the shared batch revision; use its actual current version.
update batch_test set result=result || jsonb_build_object('version',(select version from app_private.payment_link_batches where id=(result->>'id')::uuid));
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$ update batch_test set confirmed=api.admin_payment_batch_confirm((result->>'id')::uuid,(result->>'version')::integer,1200,'SHARED-RECEIVED-1200','Volledige betaling gecontroleerd','batch-test-confirm') $$,
  'the manager confirms the received joint amount once');
select is(api.admin_payment_batch_confirm((select (result->>'id')::uuid from batch_test),(select (result->>'version')::integer from batch_test),1200,'SHARED-RECEIVED-1200','Volledige betaling gecontroleerd','batch-test-confirm'),
  (select confirmed from batch_test),'confirmation retries replay the existing result');
reset role;
select is((select sum(amount_cents)::integer from app_private.payment_entries where request_id in (select first_payment from batch_test union all select second_payment from batch_test)),1200,'the ledger receives the total once, distributed into family shares');
select is((select count(*)::integer from app_private.payment_requests where id in (select first_payment from batch_test union all select second_payment from batch_test) and status='confirmed'),2,'both selected household invoices become confirmed');
select is((select sum(amount_cents)::integer from app_private.payment_entries where request_id=(select first_payment from batch_test)),200,'the one-child family ledger receives only its original share');
select is((select sum(amount_cents)::integer from app_private.payment_entries where request_id=(select second_payment from batch_test)),1000,'the five-child family ledger receives only its original share');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select ok(nullif(api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,payment,externalUrl}','') is null,'the parent cannot pay a settled joint request again');

-- Separate pending scenario for cancellation and amount-change invalidation.
reset role;
delete from app_private.payment_entries where request_id in (select first_payment from batch_test union all select second_payment from batch_test);
update app_private.payment_requests set payment_batch_id=null,status='awaiting_link',external_url=null,version=version+1
where id in (select first_payment from batch_test union all select second_payment from batch_test);
update batch_test set selection=(select jsonb_agg(jsonb_build_object('id',id,'version',version) order by case when id=(select first_payment from batch_test) then 0 else 1 end) from app_private.payment_requests
  where id in (select first_payment from batch_test union all select second_payment from batch_test));
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update batch_test set result=api.admin_payment_batch_publish('duindorp-halloween-2026',selection,'https://tikkie.me/pay/cancel-test','Nieuw betaalverzoek','batch-test-cancel-publish');
reset role;
update batch_test set selection=(select jsonb_agg(jsonb_build_object('id',id,'version',version) order by case when id=(select first_payment from batch_test) then 0 else 1 end) from app_private.payment_requests where id in (select first_payment from batch_test union all select second_payment from batch_test));
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update batch_test set result=api.admin_payment_batch_publish('duindorp-halloween-2026',selection,'https://tikkie.me/pay/cancel-corrected','Gecorrigeerd betaalverzoek','batch-test-cancel-correct');
select lives_ok($$ select api.admin_payment_batch_cancel((select (result->>'id')::uuid from batch_test),(select (result->>'version')::integer from batch_test),'Dit verzoek wordt vervangen') $$,
  'the manager can withdraw a pending shared link');
reset role;
select is((select count(*)::integer from app_private.payment_requests where id in (select first_payment from batch_test union all select second_payment from batch_test) and payment_batch_id is null and external_url is null),2,'cancellation detaches both invoices and clears their old links');
update batch_test set selection=(select jsonb_agg(jsonb_build_object('id',id,'version',version) order by case when id=(select first_payment from batch_test) then 0 else 1 end) from app_private.payment_requests
  where id in (select first_payment from batch_test union all select second_payment from batch_test));
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update batch_test set result=api.admin_payment_batch_publish('duindorp-halloween-2026',selection,'https://tikkie.me/pay/changed-total','Verzoek vóór gewijzigde inschrijving','batch-test-change-publish');
reset role;
update app_private.payment_requests set amount_cents=amount_cents+250 where id=(select first_payment from batch_test);
select is(app_private.payment_batch_payload((select (result->>'id')::uuid from batch_test))->>'status','needs_review','a changed underlying amount invalidates the shared payment link');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select ok(nullif(api.registration_snapshot('duindorp-halloween-2026') #>> '{registration,payment,externalUrl}','') is null,'the other household no longer sees a stale payable URL after an amount change');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$ select api.admin_payment_batch_confirm((select (result->>'id')::uuid from batch_test),(select (result->>'version')::integer from batch_test),1200,'OUTDATED-TOTAL','Verouderd totaal mag niet worden geboekt','batch-outdated-total') $$,
  '23514','BATCH_NEEDS_REVIEW','a changed family amount must be reviewed before any joint confirmation');
reset role;
select is((select count(*)::integer from api.worker_claim_outbox(50,30) where message_type='payment_link_ready' and payload->>'externalUrl' in (
  'https://tikkie.me/pay/shared-test','https://tikkie.me/pay/cancel-test','https://tikkie.me/pay/cancel-corrected','https://tikkie.me/pay/changed-total')),
  0,'the worker never claims a settled, corrected, cancelled or amount-invalidated payment link');
select is((select count(*)::integer from app_private.email_outbox where message_type='payment_link_ready' and status='suppressed' and last_error_code='PAYMENT_LINK_SUPERSEDED'
  and payload->>'externalUrl' in ('https://tikkie.me/pay/shared-test','https://tikkie.me/pay/cancel-test','https://tikkie.me/pay/cancel-corrected','https://tikkie.me/pay/changed-total')),
  4,'each obsolete queued payer e-mail is explicitly suppressed');
select * from finish();
rollback;
