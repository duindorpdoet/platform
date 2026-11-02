begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
\ir fixtures/duinpad-finalists.inc
-- Synthetic only: no provider, all business changes roll back.
update app_private.events set phase='live'where slug='duindorp-halloween-2026';
update app_private.portal_flags set value=false where flag_key='fixture';
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)
select('eb100000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'closed-room-'||n||'@example.invalid',now(),'{}','{}'from generate_series(1,8)n;
insert into app_private.events(id,slug,title,local_date,price_cents)values('eb200000-0000-0000-0000-000000000001','synthetic-foreign-room','Synthetic foreign room','2026-10-31',0);
insert into app_private.event_capabilities(event_id,user_id,capability,granted_by)
select case when n=3 then'eb200000-0000-0000-0000-000000000001'::uuid else e.id end,
 ('eb100000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 case when n=1 then'portals_manage'when n=2 then'live_support'else'event_admin'end,
 'f0000000-0000-0000-0000-000000000001'from app_private.events e,generate_series(1,8)n where e.slug='duindorp-halloween-2026';
insert into app_private.portal_owners(portal_id,user_id,role)values('12000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000004','viewer');
update auth.users set email_confirmed_at=null where id='eb100000-0000-0000-0000-000000000004';
update auth.users set banned_until=now()+interval'1 day'where id='eb100000-0000-0000-0000-000000000005';
update auth.users set deleted_at=now()where id='eb100000-0000-0000-0000-000000000006';
update app_private.event_capabilities set revoked_at=now()where user_id='eb100000-0000-0000-0000-000000000007';
insert into app_private.portal_thanks(event_id,household_id,portal_id,choice)
select id,'d2000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000001','beautiful'from app_private.events where slug='duindorp-halloween-2026';
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((select count(*)from app_private.portal_owners where user_id=auth.uid()),0::bigint,'organization fixture has no portal membership');
create temp table open_room as select api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')body;
select is((select body->>'eventClosed'from open_room),'false','an open event is not centrally closed');
select is((select body->'closedAt'from open_room),'null'::jsonb,'an open event has no close timestamp');
select is((select body#>>'{portal,state}'from open_room),'open','open-event room keeps its operational state');
select lives_ok($$select api.portal_set_operational_state('12000000-0000-0000-0000-000000000001','open',(select version from app_private.portals where id='12000000-0000-0000-0000-000000000001'),'Synthetic open')$$,'existing direct status command works before closure');
update app_private.portals set operation_status='paused',pause_until=now()-interval'1 minute'where id='12000000-0000-0000-0000-000000000002';
select lives_ok($$select app_private.poortkamer_tick()$$,'open-event timed pause still resumes normally');
select is((select operation_status::text from app_private.portals where id='12000000-0000-0000-0000-000000000002'),'open','open-event pause resumption remains operational');
update app_private.portals set operation_status='paused',pause_until=now()-interval'1 minute',pause_after_current=true where id='12000000-0000-0000-0000-000000000003';
-- Keep real pre-closure operational rows/history for comparison.
create temp table before_close as select id,operation_status,pause_until,pause_after_current,version from app_private.portals;
select api.event_closure_confirm('duindorp-halloween-2026','Synthetic closure','Local fixture only','eb300000-0000-0000-0000-000000000001');
select is((select jsonb_agg(to_jsonb(p)order by id)from(select id,operation_status,pause_until,pause_after_current,version from app_private.portals)p),(select jsonb_agg(to_jsonb(p)order by id)from before_close p),'central closure preserves physical operational rows and versions');
create temp table closed_room as select api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000003')body;
select is((select body->>'eventClosed'from closed_room),'true','room explicitly reports the central closure');
select is((select(body->>'closedAt')::timestamptz from closed_room),(select closed_at from app_private.event_closures where event_id=(select id from app_private.events where slug='duindorp-halloween-2026')),'room uses the genuine immutable close timestamp');
select is((select body#>>'{portal,state}'from closed_room),'closed','legacy clients also receive a closed portal state');
select is((select body#>'{portal,pauseUntil}'from closed_room),'null'::jsonb,'closed projection hides an obsolete pause countdown');
select is((select body#>>'{portal,pauseAfterCurrent}'from closed_room),'false','closed projection cannot promise a later pause/resume');
select ok((select body?'impact'and body?'registeredImpact'from closed_room),'actual and registered certificate projections remain available');
select is((select operation_status::text from app_private.portals where id='12000000-0000-0000-0000-000000000003'),'paused','room snapshot does not rewrite its historical operational state');
select is((select count(*)from app_private.portals p where p.approval_status='approved'and api.portal_room_snapshot('duindorp-halloween-2026',p.id)#>>'{portal,state}'='closed'),30::bigint,'every approved room is effectively closed, including the finale');
select throws_ok($$select api.portal_set_operational_state('12000000-0000-0000-0000-000000000001','open',(select version from app_private.portals where id='12000000-0000-0000-0000-000000000001'),'Synthetic reopen')$$,'23514','EVENING_ENDED','old direct clients cannot reopen a centrally closed room');
select throws_ok($$select api.portal_set_operational_state('12000000-0000-0000-0000-000000000003','paused',(select version from app_private.portals where id='12000000-0000-0000-0000-000000000003'),'Synthetic pause')$$,'23514','EVENING_ENDED','direct status cannot schedule another pause after closure');
select throws_ok($$select api.portal_room_update('12000000-0000-0000-0000-000000000001','status',jsonb_build_object('state','open','version',(select version from app_private.portals where id='12000000-0000-0000-0000-000000000001')),'eb300000-0000-0000-0000-000000000002')$$,'23514','EVENING_ENDED','room command rejects reopen before its inner row locks and receipt');
select throws_ok($$update app_private.portals set operation_status='open'where id='12000000-0000-0000-0000-000000000003'$$,'23514','EVENING_ENDED','other existing management writers cannot transition a closed-event portal to open');
select throws_ok($$update app_private.portals set operation_status='scheduled'where id='12000000-0000-0000-0000-000000000003'$$,'23514','EVENING_ENDED','a centrally closed portal cannot return to scheduled');
select lives_ok($$select api.portal_room_update('12000000-0000-0000-0000-000000000001','checklist','{"item":"lighting","done":true}','eb300000-0000-0000-0000-000000000003')$$,'non-status room commands retain their existing semantics');
select lives_ok($$select app_private.poortkamer_tick()$$,'closed-event tick completes without attempting a reopen');
select is((select operation_status::text from app_private.portals where id='12000000-0000-0000-0000-000000000003'),'paused','expired timed pause cannot reactivate a centrally closed event');
select is((select count(*)from app_private.portal_status_history where portal_id='12000000-0000-0000-0000-000000000003'and state='open'),0::bigint,'tick invents no post-closure open history');
select lives_ok($$select api.portal_set_operational_state('12000000-0000-0000-0000-000000000002','closed',(select version from app_private.portals where id='12000000-0000-0000-0000-000000000002'),'Synthetic explicit stop')$$,'existing explicit safety stop remains allowed');

-- The new helper grants exactly existing room management capabilities; it does
-- not change mail eligibility or leak sender/account data.
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,'Bedankt voor jullie inzet en de mooie Halloweenavond! Dankzij jullie hebben we samen kunnen griezelen in Duindorp. 🎃','eb400000-0000-0000-0000-000000000001');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000001','welcome','Dank voor de rustige ontvangst!','eb400000-0000-0000-0000-000000000002');
do $$begin for n in 1..3 loop perform api.worker_house_thanks_fanout(25);end loop;end $$;
create temp table preserved_mail as select jsonb_agg(to_jsonb(o)order by id)body from app_private.email_outbox o;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table organization_inbox as select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')body;
select is((select body->>'total'from organization_inbox),'2','organization without ownership reads real central receipt counts');
select is((select body->>'aggregateOnlyCount'from organization_inbox),'1','standard thanks remain counter only');
select is((select body->>'customMessageCount'from organization_inbox),'1','organization sees the one written personal message');
select is((select body->'counters'from organization_inbox),'{"general":1,"personal":1,"beautiful":0,"welcome":1,"treats":0}'::jsonb,'organization inbox preserves all existing counter meanings');
select is((select body->'messages'->0->>'message'from organization_inbox),'Dank voor de rustige ontvangst!','organization receives the actual stored message');
select lives_ok($$select api.portal_thanks_read('duindorp-halloween-2026',(select(body->'messages'->0->>'id')::uuid from organization_inbox))$$,'the same room-capability boundary permits personal read acknowledgement');
select is(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')->>'unread','0','organization read acknowledgement is retained for its own account');
select ok(not((select body::text from organization_inbox)~'d1000000|householdId|duinpad-.*@|Oefenkind'),'new capability access exposes no family identifiers');
select set_config('request.jwt.claims','{"sub":"eb100000-0000-0000-0000-000000000008","role":"authenticated"}',true);
select is((select count(*)from app_private.portal_owners where user_id=auth.uid()),0::bigint,'event_admin-only fixture owns no portal');
select is((select count(*)from app_private.event_capabilities where user_id=auth.uid()and revoked_at is null),1::bigint,'organization fixture has only event_admin, without portals_manage');
select is(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')->>'total','2','event_admin alone reads the genuine two central receipts');
create temp table organization_legacy as select api.portal_thanks_snapshot('duindorp-halloween-2026','house','12000000-0000-0000-0000-000000000001')body;
select is((select body->>'familyCount'from organization_legacy),'1','same event_admin alone reads the preserved legacy reaction');
select is((select body->'thanks'->0->>'choice'from organization_legacy),'beautiful','legacy choice is projected from its real stored history');
select ok(not((select body::text from organization_legacy)~'d2000000|householdId|accountId|@|Oefenkind'),'legacy projection exposes no household or account identifiers');
select is(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')->>'total','2','legacy reactions remain separate from canonical central receipt counts');

select set_config('request.jwt.claims','{"sub":"eb100000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')->>'total','2','existing portals_manage room capability can read its inbox');
select set_config('request.jwt.claims','{"sub":"eb100000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select is(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')->>'total','2','existing live_support room capability can read its inbox');
select is(jsonb_array_length(api.portal_thanks_snapshot('duindorp-halloween-2026','house','12000000-0000-0000-0000-000000000001')->'thanks'),1,'live_support also reads the same safe legacy room projection');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select is(api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')->>'unread','1','an existing viewer reads without sharing another account read status');
select throws_ok($$select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000002')$$,'42501','NOT_AUTHORIZED','viewer cannot read a foreign portal');
select throws_ok($$select api.portal_thanks_read('synthetic-foreign-room',(select(body->'messages'->0->>'id')::uuid from organization_inbox))$$,'42501','NOT_AUTHORIZED','read acknowledgement cannot cross event slug');
select set_config('request.jwt.claims','{"sub":"eb100000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select throws_ok($$select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','a foreign-event administrator has no access');
select throws_ok($$select api.portal_thanks_snapshot('duindorp-halloween-2026','house','12000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','legacy projection rejects a foreign-event administrator too');
select set_config('request.jwt.claims','{"sub":"eb100000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select throws_ok($$select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','unverified administrator is rejected');
select throws_ok($$select api.portal_thanks_snapshot('duindorp-halloween-2026','house','12000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','legacy access retains verified-account privacy');
select set_config('request.jwt.claims','{"sub":"eb100000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select throws_ok($$select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','banned administrator is rejected');
select set_config('request.jwt.claims','{"sub":"eb100000-0000-0000-0000-000000000006","role":"authenticated"}',true);
select throws_ok($$select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','deleted administrator is rejected');
select set_config('request.jwt.claims','{"sub":"eb100000-0000-0000-0000-000000000007","role":"authenticated"}',true);
select throws_ok($$select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','revoked capability cannot read');
select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
update app_private.portal_owners set suspended_at=now()where portal_id='12000000-0000-0000-0000-000000000001'and user_id=auth.uid();
select throws_ok($$select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','suspended portal membership stays rejected');
select throws_ok($$select api.portal_set_operational_state('12000000-0000-0000-0000-000000000001','open',1,'Synthetic unauthorized')$$,'42501','NOT_AUTHORIZED','status guard preserves authorization before close-state errors');
select set_config('request.jwt.claims','{}',true);
select throws_ok($$select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001')$$,'42501','NOT_AUTHORIZED','anonymous access stays rejected');
select is((select jsonb_agg(to_jsonb(o)order by id)from app_private.email_outbox o),(select body from preserved_mail),'inbox/read/status projections neither replay mail nor change existing mail state/payload');
select is((select p.provolatile::text from pg_proc p where p.oid='api.portal_room_snapshot(text,uuid)'::regprocedure),'v','the inherited room snapshot stays VOLATILE');
select ok(not has_function_privilege('authenticated','app_private.portal_operation_assert_allowed(uuid,text)','EXECUTE')and not has_function_privilege('service_role','app_private.portal_closed_event_operation_guard()','EXECUTE'),'new private guard helpers have no public/API role execution');
select ok(not(select prosecdef from pg_proc where oid='app_private.portal_closed_event_operation_guard()'::regprocedure),'the defensive trigger introduces no SECURITY DEFINER privilege');
select *from finish();
rollback;
