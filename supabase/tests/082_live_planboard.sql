begin;
\ir helpers/ready_live_planboard.inc
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table board(eid uuid,gid uuid,pid uuid,point uuid,schedule uuid,snapshot jsonb,vid uuid,command jsonb,preview jsonb,result jsonb,mail_count bigint);
insert into board(eid,gid,pid) select id,'23000000-0000-0000-0000-000000000002','12000000-0000-0000-0000-000000000001' from app_private.events where slug='duindorp-halloween-2026';
update app_private.event_route_settings set first_start_at='2026-10-31T15:00Z',global_ordinary_stop_at='2026-10-31T19:30Z',final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T18:00Z',finale_last_arrival_at='2026-10-31T20:30Z',finale_closes_at='2026-10-31T21:00Z',finale_max_concurrent_groups=20,finale_max_concurrent_children=200,finale_available=true,planner_mode='dynamic' where event_id=(select eid from board);
-- This regression needs a short, real route with room for a later bulk move.
-- Limit the available physical houses, never the maximizer's visit count.
update app_private.portals set operation_status='paused'
 where event_id=(select eid from board) and id not in(
 '12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000002',
 '12000000-0000-0000-0000-000000000003','12000000-0000-0000-0000-000000000030');
update app_private.registrations set requested_ordinary_stop_at=null,preferred_start_at=null where id in(select registration_id from app_private.group_registrations where group_id=(select gid from board));
update board set point=(api.admin_portal_start_point_set(pid,true,(select version from app_private.portals where id=pid))->>'startPointId')::uuid;
select api.admin_startregie_confirm_point('duindorp-halloween-2026',point,(select version from app_private.start_points where id=point)) from board;
select app_private.withdraw_group_appointment(gid,'Synthetische seedafspraak bewust vervangen voor planbordregressie')from board;
update board set schedule=(api.admin_startregie_move_group(gid,point,'2026-10-31T17:00Z',(select version from app_private.walking_groups where id=gid),'neutral','Live planbord synthetische keten voorbereiden')->>'id')::uuid;
update board set snapshot=pg_temp.ready_live_planboard('duindorp-halloween-2026');
select ok(jsonb_array_length((select snapshot->'visits' from board))>1,'explicit fixture review stores a full durable route; snapshot only projects it');
select is((select snapshot->>'inputHash' from board),api.admin_live_planboard_snapshot('duindorp-halloween-2026')->>'inputHash','read refresh keeps stable visit identities and versions');
select ok(not exists(select 1 from jsonb_array_elements((select snapshot->'visits' from board)) v where v->>'status'<>'planned'),'passing a planned clock never creates arrival or completion');
select ok(not has_table_privilege('authenticated','app_private.live_route_visits','select'),'durable route intentions remain private');
update board set vid=(select id from app_private.live_route_visits where group_id=gid and sequence=2),mail_count=(select count(*) from app_private.email_outbox);
update board set command=jsonb_build_object('action','move','visitId',vid,'portalId',(select portal_id from app_private.live_route_visits where id=vid),'startsAt',(select date_trunc('hour',starts_at)+ceil(extract(minute from starts_at)/10)*interval '10 minutes'+interval '10 minutes' from app_private.live_route_visits where id=vid),'shiftFollowing',true);
update board set preview=api.admin_live_planboard_preview('duindorp-halloween-2026',command,snapshot->>'inputHash');
select ok(jsonb_array_length((select preview->'changes' from board))>1,'move-following preview identifies all future affected visits');
select is((select count(*) from app_private.email_outbox),(select mail_count from board),'preview and cancellation do not queue mail');
savepoint ordinary_deadline;
update board set command=command||jsonb_build_object('startsAt','2026-10-31T19:30:00Z','shiftFollowing',false);
update board set preview=api.admin_live_planboard_preview('duindorp-halloween-2026',command,snapshot->>'inputHash');
select ok(exists(select 1 from board,jsonb_array_elements(preview->'warnings') warning where warning->>'code'='ORDINARY_STOP_LIMIT'),
 'a visit ending beyond the actual ordinary deadline is explicitly blocked in preview');
select throws_like($$select api.admin_live_planboard_apply('duindorp-halloween-2026',command,snapshot->>'inputHash',false,'Werkelijke gewone stopgrens bewust overschrijden','planboard-after-deadline-01') from board$$,
 'PLANBOARD_DOMAIN_BLOCKED:%ORDINARY_STOP_LIMIT%','apply independently refuses the real deadline violation');
select is(app_private.live_planboard_hash((select eid from board)),(select snapshot->>'inputHash' from board),'rejected late move preserves the complete planboard');
select is((select count(*) from app_private.email_outbox),(select mail_count from board),'rejected late move queues no mail');
rollback to savepoint ordinary_deadline;
select lives_ok($$update board set result=api.admin_live_planboard_apply('duindorp-halloween-2026',command,snapshot->>'inputHash',false,'Volgende stops bewust gelijkmatig verschuiven','planboard-concept-apply-01')$$,'unconfirmed concept can be applied without pretending it was published');
select is((select count(*) from app_private.email_outbox),(select mail_count from board),'draft route shift queues no start-time mail');
select is((select count(distinct ((v->>'startsAt')::timestamptz-(old->>'startsAt')::timestamptz)) from board,jsonb_array_elements(result->'after') v join jsonb_array_elements(result->'before') old on old->>'id'=v->>'id'),1::bigint,'all shifted stops retain their relative spacing');
select is((select api.admin_live_planboard_apply('duindorp-halloween-2026',command,snapshot->>'inputHash',false,'Volgende stops bewust gelijkmatig verschuiven','planboard-concept-apply-01') from board),(select result from board),'uncertain retry is idempotent despite new current versions');
select throws_ok($$select api.admin_live_planboard_preview('duindorp-halloween-2026',command,snapshot->>'inputHash') from board$$,'40001','STALE_VERSION','another admin cannot reuse a stale snapshot');
select lives_ok($$select api.admin_live_planboard_apply('duindorp-halloween-2026','{"action":"undo","restoreKey":"planboard-concept-apply-01"}',app_private.live_planboard_hash(eid),false,'Dezelfde conceptwijziging gecontroleerd ongedaan maken','planboard-undo-apply-01') from board$$,'undo uses original server receipt and revalidates current domain');
select lives_ok($$select api.admin_live_planboard_apply('duindorp-halloween-2026','{"action":"redo","restoreKey":"planboard-concept-apply-01"}',app_private.live_planboard_hash(eid),false,'Dezelfde conceptwijziging gecontroleerd opnieuw toepassen','planboard-redo-apply-01') from board$$,'redo preserves the same domain checks');
select throws_ok($$select api.admin_live_planboard_preview('duindorp-halloween-2026',command||jsonb_build_object('startsAt','2026-10-31T17:13Z'),app_private.live_planboard_hash(eid)) from board$$,'22023','INVALID_SNAP_OR_DURATION','server enforces ten-minute manual begin grid');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select throws_ok($$select api.admin_live_planboard_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','parent cannot read the complete private evening route');
select * from finish();
rollback;
