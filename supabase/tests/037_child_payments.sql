begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temporary table child_pay_test (
  selection jsonb, third_selection jsonb, other_selection jsonb,
  joint jsonb, single jsonb, other_batch jsonb, confirmed jsonb,
  payment_version integer
) on commit drop;
grant select, update on child_pay_test to authenticated, service_role;
insert into child_pay_test(selection,third_selection,other_selection)
values (
 '[{"id":"25000083-0000-0000-0000-000000000001","version":1},{"id":"25000083-0000-0000-0000-000000000002","version":1}]',
 '[{"id":"25000083-0000-0000-0000-000000000003","version":1}]',
 '[{"id":"25000084-0000-0000-0000-000000000001","version":1}]'
);
select ok(not has_function_privilege('anon','api.admin_child_payment_publish(text,jsonb,uuid,text,text,text)','execute'),'anonymous cannot publish child payment requests');
select ok(not has_table_privilege('authenticated','app_private.child_payment_batches','select'),'child batch links cannot be read directly');
select ok(not has_table_privilege('authenticated','app_private.child_payment_members','insert'),'participants cannot change batch membership');
select ok((select relrowsecurity from pg_class where oid='app_private.child_payment_batches'::regclass),'batch storage has RLS defense in depth');
select is((select count(*)::integer from app_private.registration_children where registration_id='22000000-0000-0000-0000-000000000083'),3,'isolated registration has three independently payable children');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000083","role":"authenticated"}',true);
select throws_ok($$select api.admin_child_payments_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','a parent cannot enumerate other children through the admin API');
select throws_ok($$select api.admin_child_payment_publish('duindorp-halloween-2026',(select selection from child_pay_test),'25000083-0000-0000-0000-000000000001','https://betaalverzoek.ing.nl/verzoek/child-test','Kindselectie gecontroleerd','child-forbidden')$$,'42501','NOT_AUTHORIZED','a parent cannot publish child payment links');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_child_payment_publish('duindorp-halloween-2026',(select selection from child_pay_test),'25000083-0000-0000-0000-000000000001','https://user@attacker.invalid/pay/test','Kindselectie gecontroleerd','child-host')$$,'22023','VALIDATION_ERROR','payment URL credentials are rejected');
select throws_ok($$select api.admin_child_payment_publish('duindorp-halloween-2026',(select jsonb_build_array(selection->0,selection->0) from child_pay_test),'25000083-0000-0000-0000-000000000001','https://betaalverzoek.ing.nl/verzoek/child-test','Kindselectie gecontroleerd','child-duplicate')$$,'22023','VALIDATION_ERROR','duplicate child cannot inflate amount');
select throws_ok($$select api.admin_child_payment_publish('duindorp-halloween-2026',(select selection from child_pay_test),'25000083-0000-0000-0000-000000000003','https://betaalverzoek.ing.nl/verzoek/child-test','Kindselectie gecontroleerd','child-anchor')$$,'22023','INVALID_ANCHOR_CHILD','anchor must belong to selected children');
select throws_ok($$select api.admin_child_payment_publish('duindorp-halloween-2026',(select jsonb_set(selection,'{1,version}','999') from child_pay_test),'25000083-0000-0000-0000-000000000001','https://betaalverzoek.ing.nl/verzoek/child-test','Kindselectie gecontroleerd','child-stale')$$,'40001','STALE_VERSION','one stale child rolls back the complete selection');
reset role;
select is((select count(*)::integer from app_private.registration_children where registration_id='22000000-0000-0000-0000-000000000083' and child_payment_batch_id is not null),0,'failed publish links no children');
select is((select count(*)::integer from app_private.email_outbox where payload->>'externalUrl'='https://betaalverzoek.ing.nl/verzoek/child-test'),0,'failed publish creates no e-mail');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$update child_pay_test set joint=api.admin_child_payment_publish('duindorp-halloween-2026',selection,'25000083-0000-0000-0000-000000000001','https://betaalverzoek.ing.nl/verzoek/child-test','Kindselectie gecontroleerd','child-publish')$$,'two siblings can share one payment link');
select is((select (joint->>'totalAmountCents')::integer from child_pay_test),500,'two selected children total 500 cents');
select is((select jsonb_array_length(joint->'childNames') from child_pay_test),2,'batch describes only the two selected children');
select is(api.admin_child_payment_publish('duindorp-halloween-2026',(select selection from child_pay_test),'25000083-0000-0000-0000-000000000001','https://betaalverzoek.ing.nl/verzoek/child-test','Kindselectie gecontroleerd','child-publish'),(select joint from child_pay_test),'publication replay returns the original batch');
reset role;
select is((select child_payment_batch_id from app_private.registration_children where id='26000083-0000-0000-0000-000000000003'),null::uuid,'third sibling remains unlinked');
select is((select payment_version from app_private.registration_children where id='26000083-0000-0000-0000-000000000003'),1,'third sibling version is unchanged');
select is((select count(*)::integer from app_private.email_outbox where message_type='payment_link_ready' and payload->>'childBatchId'=(select joint->>'id' from child_pay_test)),1,'one adult receives exactly one e-mail despite two selected children and replay');
select is((select payload->'paymentChildren' from app_private.email_outbox where message_type='payment_link_ready' and payload->>'childBatchId'=(select joint->>'id' from child_pay_test)), '["Betaalkind Alfa 1","Betaalkind Alfa 2"]'::jsonb,'mail identifies the covered children');
select is((select payload->>'anchorChildName' from app_private.email_outbox where message_type='payment_link_ready' and payload->>'childBatchId'=(select joint->>'id' from child_pay_test)),'Betaalkind Alfa 1','mail identifies the one active payment child');
update child_pay_test set payment_version=(select version from app_private.payment_requests where id='28000000-0000-0000-0000-000000000083');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.payment_set_external_link('28000000-0000-0000-0000-000000000083',(select payment_version from child_pay_test),'https://tikkie.me/pay/old-api','Oude route mag niet dubbel innen')$$,'23514','CHILD_PAYMENT_REQUIRES_BATCH','legacy direct link cannot replace a child-mode request');
select throws_ok($$select api.payment_confirm_versioned('28000000-0000-0000-0000-000000000083',(select payment_version from child_pay_test),750,'OLD-CHILD-REF','Oude route mag niet dubbel innen','child-old-confirm','child-old-confirm')$$,'23514','CHILD_PAYMENT_REQUIRES_BATCH','legacy registration confirmation cannot collect child invoices again');
select lives_ok($$update child_pay_test set single=api.admin_child_payment_publish('duindorp-halloween-2026',third_selection,'25000083-0000-0000-0000-000000000003','https://tikkie.me/pay/third-child','Derde kind apart betalen','third-publish')$$,'third sibling gets a separate payment link');
select is((select (single->>'totalAmountCents')::integer from child_pay_test),250,'separate child amount is 250 cents');
select isnt((select single->>'id' from child_pay_test),(select joint->>'id' from child_pay_test),'separate request has independent identity');

select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000084","role":"authenticated"}',true);
select throws_ok($$select api.child_payment_report((select (joint->>'id')::uuid from child_pay_test),1)$$,'42501','NOT_AUTHORIZED','a different household cannot report the anchor household payment');
select ok(api.registration_snapshot('duindorp-halloween-2026')::text not like '%https://betaalverzoek.ing.nl/verzoek/child-test%','another household snapshot contains no sibling payment URL');
select ok(api.registration_snapshot('duindorp-halloween-2026')::text not like '%Betaalkind Alfa%','another household snapshot does not disclose private child names');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000083","role":"authenticated"}',true);
select is((api.registration_snapshot('duindorp-halloween-2026')#>>'{registration,children,0,payment,batch,anchorChildId}'),'25000083-0000-0000-0000-000000000001','parent snapshot gives the actual child anchor identity');
select lives_ok($$update child_pay_test set joint=api.child_payment_report((joint->>'id')::uuid,(joint->>'version')::integer)$$,'anchor household can report the shared payment');
select is((select joint->>'status' from child_pay_test),'reported','report awaits bank verification');
select is((select joint->>'externalUrl' from child_pay_test),null::text,'reported batch no longer exposes a payment link');

select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_child_payment_confirm((select (joint->>'id')::uuid from child_pay_test),(select (joint->>'version')::integer from child_pay_test),250,'WRONG-AMOUNT','Werkelijke ontvangst controleren','wrong-total')$$,'23514','BATCH_AMOUNT_MISMATCH','partial shared receipt cannot falsely pay two children');
select lives_ok($$update child_pay_test set confirmed=api.admin_child_payment_confirm((joint->>'id')::uuid,(joint->>'version')::integer,500,'CHILD-JOINT-REF','Werkelijke ontvangst gecontroleerd','child-confirm')$$,'confirmed 500 cents covers exactly two siblings');
select is(api.admin_child_payment_confirm((select (joint->>'id')::uuid from child_pay_test),(select (joint->>'version')::integer from child_pay_test),500,'CHILD-JOINT-REF','Werkelijke ontvangst gecontroleerd','child-confirm'),(select confirmed from child_pay_test),'confirmation replay returns same receipt');
reset role;
select is((select status::text from app_private.payment_requests where id='28000000-0000-0000-0000-000000000083'),'partial','registration total remains partially paid');
select is((select count(*)::integer from app_private.payment_entries where request_id='28000000-0000-0000-0000-000000000083' and entry_type='payment'),1,'replay adds no accounting entry');
select is((select sum(amount_cents)::integer from app_private.payment_entries where request_id='28000000-0000-0000-0000-000000000083'),500,'only 500 cents booked so far');
select is(app_private.child_payment_payload('26000083-0000-0000-0000-000000000003')->>'status','awaiting_payment','third sibling remains unpaid');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_child_payment_confirm((select (single->>'id')::uuid from child_pay_test),(select (single->>'version')::integer from child_pay_test),250,'CHILD-SINGLE-REF','Derde ontvangst gecontroleerd','third-confirm')$$,'separate third receipt finishes the registration');
reset role;
select is((select status::text from app_private.payment_requests where id='28000000-0000-0000-0000-000000000083'),'confirmed','750 cents confirms the registration');
select is((select sum(amount_cents)::integer from app_private.payment_entries where request_id='28000000-0000-0000-0000-000000000083'),750,'ledger total is exactly 750 cents');
select is((select count(*)::integer from app_private.payment_entries where request_id='28000000-0000-0000-0000-000000000083' and entry_type='payment'),2,'one entry per settled child batch');

-- A cancellation invalidates a live request before it can be paid or confirmed.
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$update child_pay_test set other_batch=api.admin_child_payment_publish('duindorp-halloween-2026',other_selection,'25000084-0000-0000-0000-000000000001','https://tikkie.me/pay/cancelled-child','Extra kind voor wijzigingstest','other-publish')$$,'independent household gets a request');
reset role;
update app_private.registration_children set participation_status='cancelled' where id='26000084-0000-0000-0000-000000000001';
select is(app_private.child_payment_batch_payload((select (other_batch->>'id')::uuid from child_pay_test))->>'status','needs_review','child cancellation marks the existing payment link unsafe');
select is(app_private.child_payment_batch_payload((select (other_batch->>'id')::uuid from child_pay_test))->>'externalUrl',null::text,'invalidated payment URL is suppressed');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000084","role":"authenticated"}',true);
select throws_ok($$select api.child_payment_report((select (other_batch->>'id')::uuid from child_pay_test),1)$$,'23514','BATCH_NEEDS_REVIEW','parent cannot report a cancelled child request');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_child_payment_confirm((select (other_batch->>'id')::uuid from child_pay_test),1,250,'INVALID-CHILD','Annulering moet eerst worden verwerkt','cancelled-confirm')$$,'23514','BATCH_NEEDS_REVIEW','organization cannot confirm invalidated membership');
select lives_ok($$select api.admin_child_payment_cancel((select (other_batch->>'id')::uuid from child_pay_test),1,'Oud verzoek intrekken na afmelding')$$,'organization can explicitly release invalidated request');
reset role;
select is((select child_payment_batch_id from app_private.registration_children where id='26000084-0000-0000-0000-000000000001'),null::uuid,'cancelled batch releases its child');
update app_private.registration_children set participation_status='active' where id='26000084-0000-0000-0000-000000000001';
update child_pay_test set other_selection=(select jsonb_build_array(jsonb_build_object('id',child_id,'version',payment_version)) from app_private.registration_children where id='26000084-0000-0000-0000-000000000001');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_child_payment_publish('duindorp-halloween-2026',(select other_selection from child_pay_test),'25000084-0000-0000-0000-000000000001','https://tikkie.me/pay/restored-child','Kind weer aangemeld met nieuw verzoek','restored-publish')$$,'released child can receive a fresh request with its new version');
reset role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
set local role service_role;
select lives_ok($$select * from api.worker_claim_outbox(100,120)$$,'mail worker can claim current child notifications');
reset role;
select is((select count(*)::integer from app_private.email_outbox where message_type='payment_link_ready' and payload->>'externalUrl' in('https://betaalverzoek.ing.nl/verzoek/child-test','https://tikkie.me/pay/third-child','https://tikkie.me/pay/cancelled-child') and status='suppressed'),3,'settled and cancelled payment-link mails are suppressed before delivery');
select is((select count(*)::integer from app_private.email_outbox where message_type='payment_link_ready' and payload->>'externalUrl'='https://tikkie.me/pay/restored-child' and status='suppressed'),0,'current replacement mail remains deliverable');

-- Paid child history survives cancellation; refunds apply to one exact paid set.
update app_private.registration_children set participation_status='cancelled' where id='26000083-0000-0000-0000-000000000001';
update app_private.payment_requests set amount_cents=500,status='refund_due',version=version+1 where id='28000000-0000-0000-0000-000000000083';
select is(app_private.child_payment_payload('26000083-0000-0000-0000-000000000001')->>'status','cancelled','cancelled child is not presented as active');
select is(app_private.child_payment_payload('26000083-0000-0000-0000-000000000002')->>'status','confirmed','active sibling remains paid when the other covered child cancels');
select is(app_private.child_payment_payload('26000083-0000-0000-0000-000000000003')->>'status','confirmed','separate paid sibling remains confirmed after cancellation');
select is(app_private.child_payment_batch_payload((select (joint->>'id')::uuid from child_pay_test))->>'status','confirmed','cancellation does not rewrite already verified bank receipt');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000083","role":"authenticated"}',true);
select throws_ok($$select api.admin_child_payment_refund((select (confirmed->>'id')::uuid from child_pay_test),(select (confirmed->>'version')::integer from child_pay_test),500,'PARENT-REFUND','Ouder mag geen terugbetaling vastleggen','child-forbidden-refund')$$,'42501','NOT_AUTHORIZED','parents cannot record a refund');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.payment_refund('28000000-0000-0000-0000-000000000083',500,'LEGACY-REFUND','Oude route mag geen kinderen samen terugboeken','old-child-refund','old-child-refund')$$,'23514','CHILD_PAYMENT_REQUIRES_BATCH','whole-registration refund API cannot bypass child batch accounting');
select throws_ok($$select api.admin_child_payment_refund((select (confirmed->>'id')::uuid from child_pay_test),(select (confirmed->>'version')::integer from child_pay_test),250,'WRONG-REFUND','Volledige betaallink-terugbetaling controleren','wrong-child-refund')$$,'23514','BATCH_AMOUNT_MISMATCH','partial batch refund cannot erase both covered obligations');
select lives_ok($$update child_pay_test set other_batch=api.admin_child_payment_refund((confirmed->>'id')::uuid,(confirmed->>'version')::integer,500,'CHILD-REFUND-REF','Werkelijk uitgevoerde terugbetaling gecontroleerd','child-refund')$$,'organizer records exactly 500 cents returned for the shared pair');
select is(api.admin_child_payment_refund((select (confirmed->>'id')::uuid from child_pay_test),(select (confirmed->>'version')::integer from child_pay_test),500,'CHILD-REFUND-REF','Werkelijk uitgevoerde terugbetaling gecontroleerd','child-refund'),(select other_batch from child_pay_test),'refund replay returns the original result without another refund');
reset role;
select is((select count(*)::integer from app_private.payment_entries where request_id='28000000-0000-0000-0000-000000000083' and entry_type='refund'),1,'replayed refund creates exactly one negative ledger entry');
select is((select sum(amount_cents)::integer from app_private.payment_entries where request_id='28000000-0000-0000-0000-000000000083' and entry_type='refund'),-500,'refund ledger contains exactly minus 500 cents');
select is((select sum(amount_cents)::integer from app_private.payment_entries where request_id='28000000-0000-0000-0000-000000000083'),250,'separate third child retains its 250 cents of payment');
select is((select status from app_private.child_payment_batches where id=(select (joint->>'id')::uuid from child_pay_test)),'refunded','only the requested shared batch is refunded');
select is(app_private.child_payment_payload('26000083-0000-0000-0000-000000000003')->>'status','confirmed','separate third sibling stays confirmed after the shared refund');
select is((select count(*)::integer from app_private.payment_entries where child_payment_batch_id=(select (single->>'id')::uuid from child_pay_test)),1,'third sibling ledger has no extra payment or refund entry');
select is((select child_payment_batch_id from app_private.registration_children where id='26000083-0000-0000-0000-000000000002'),null::uuid,'refunded active sibling is released for a future new request');
select is(app_private.child_payment_payload('26000083-0000-0000-0000-000000000002')->>'status','awaiting_link','refunded sibling must await a new link instead of retaining paid access');

select * from finish();
rollback;
