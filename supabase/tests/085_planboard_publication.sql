begin;
\ir helpers/ready_live_planboard.inc
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
create temp table board(eid uuid,gid uuid,pid uuid,point uuid,schedule uuid,snapshot jsonb,vid uuid,command jsonb,preview jsonb,result jsonb,mail_count bigint);
insert into board(eid,gid,pid) select id,'23000000-0000-0000-0000-000000000002','12000000-0000-0000-0000-000000000001' from app_private.events where slug='duindorp-halloween-2026';
update app_private.event_route_settings set first_start_at='2026-10-31T15:00Z',global_ordinary_stop_at='2026-10-31T19:30Z',final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T18:00Z',finale_last_arrival_at='2026-10-31T20:30Z',finale_closes_at='2026-10-31T21:00Z',finale_max_concurrent_groups=20,finale_max_concurrent_children=200,finale_available=true,planner_mode='dynamic' where event_id=(select eid from board);
update app_private.walking_groups set desired_ordinary_visits=3 where id=(select gid from board);
update app_private.registrations set requested_ordinary_stop_at=null,preferred_start_at=null where id in(select registration_id from app_private.group_registrations where group_id=(select gid from board));
update board set point=(api.admin_portal_start_point_set(pid,true,(select version from app_private.portals where id=pid))->>'startPointId')::uuid;
select api.admin_startregie_confirm_point('duindorp-halloween-2026',point,(select version from app_private.start_points where id=point)) from board;
select app_private.withdraw_group_appointment(gid,'Synthetische seedafspraak bewust vervangen voor planbordregressie')from board;
update board set schedule=(api.admin_startregie_move_group(gid,point,'2026-10-31T17:00Z',(select version from app_private.walking_groups where id=gid),'neutral','Live planbord synthetische keten voorbereiden')->>'id')::uuid;
update board set snapshot=pg_temp.ready_live_planboard('duindorp-halloween-2026');

select api.admin_startregie_confirm_and_send('duindorp-halloween-2026',jsonb_build_array(jsonb_build_object('id',schedule,'revision',(select revision from app_private.group_schedule_revisions where id=schedule))),(select settings_version from app_private.events where id=eid),'planboard-initial-publication-01') from board;
create temp table board_recipients as select * from app_private.group_adult_recipients((select gid from board));
select api.worker_group_schedule_mail_payload(id) from app_private.email_outbox where payload->>'groupId'=(select gid::text from board) and message_type='group_schedule_published';
update app_private.email_outbox set status='accepted',provider='sendgrid',provider_id='legacy-accepted-'||id::text,accepted_at=clock_timestamp() where payload->>'groupId'=(select gid::text from board) and message_type='group_schedule_published';
update board set snapshot=api.admin_live_planboard_snapshot('duindorp-halloween-2026'),mail_count=(select count(*) from app_private.email_outbox);
update board set vid=(select id from app_private.live_route_visits where group_id=gid order by sequence limit 1);
update board set command=jsonb_build_object('action','move','visitId',vid,'portalId',pid,'startsAt','2026-10-31T17:10:00Z','shiftFollowing',true);
update board set preview=api.admin_live_planboard_preview('duindorp-halloween-2026',command,snapshot->>'inputHash');
select is((select preview->>'requiresConfirmation' from board),'true','published first stop requires explicit confirmation before even saving a draft');
select is((app_private.current_start_publication((select gid from board))).starts_at,'2026-10-31T17:00Z'::timestamptz,'preview/cancel preserves the published time');
select is((select count(*) from app_private.email_outbox),(select mail_count from board),'preview/cancel sends no mail');
savepoint proposed_start_window;
update app_private.start_points set available_until='2026-10-31T17:05Z'where id=(select point from board);
select throws_ok($$select api.admin_live_planboard_preview('duindorp-halloween-2026',command,app_private.live_planboard_hash(eid))from board$$,
 '23514','START_POINT_CLOSED','start correction preview validates gathering availability at the proposed time');
rollback to savepoint proposed_start_window;
select throws_ok($$select api.admin_live_planboard_apply('duindorp-halloween-2026',command,snapshot->>'inputHash',false,'Gepubliceerde start niet zonder bevestiging aanpassen','published-without-consent-01') from board$$,'P0001','CONFIRMATION_REQUIRED','server refuses missing confirmation');
select lives_ok($$select api.admin_live_planboard_apply('duindorp-halloween-2026',command,snapshot->>'inputHash',true,'Gepubliceerde start als nieuw concept voorstellen','published-draft-consent-01') from board$$,'explicitly reviewed change creates a concept');
select is((app_private.current_start_publication((select gid from board))).starts_at,'2026-10-31T17:00Z'::timestamptz,'old publication remains authoritative while the concept is edited');
select is((select count(*) from app_private.email_outbox),(select mail_count from board),'confirmed concept save still creates no time mail');
update board set snapshot=api.admin_live_planboard_snapshot('duindorp-halloween-2026'),schedule=(select current_schedule_revision_id from app_private.walking_groups where id=gid);
create temp table before_correction as select plan.accepted_version_id,
 (select jsonb_agg(to_jsonb(visit)order by visit.id)from app_private.live_route_visits visit where visit.group_id=plan.group_id) visits
 from app_private.live_route_plans plan where plan.group_id=(select gid from board);
select lives_ok($$select api.admin_live_planboard_publish('duindorp-halloween-2026',gid,snapshot->>'inputHash',schedule,(select revision from app_private.group_schedule_revisions where id=schedule),(select settings_version from app_private.events where id=eid),'planboard-replacement-publication-01') from board$$,'publication reuses the existing atomic confirmation/outbox command');
select is((app_private.current_start_publication((select gid from board))).starts_at,'2026-10-31T17:10Z'::timestamptz,'replacement publication becomes authoritative');
select ok(not app_private.canonical_route_group_current((select gid from board)),
 'explicitly publishing a replacement start requires a new joint route review');
select is((select jsonb_build_array(plan.accepted_version_id,(select jsonb_agg(to_jsonb(visit)order by visit.id)from app_private.live_route_visits visit where visit.group_id=plan.group_id))
 from app_private.live_route_plans plan where plan.group_id=(select gid from board)),
 (select jsonb_build_array(accepted_version_id,visits)from before_correction),
 'replacement publication preserves the existing physical intentions and accepted history until explicit recomputation');
select is((select count(*) from app_private.email_outbox)-(select mail_count from board),(select count(*) from board_recipients),'publication creates exactly one semantic correction per intended adult recipient');
select is((select count(*) from app_private.email_outbox o join board_recipients r on r.user_id::text=o.recipient_ref and r.email=o.recipient_email where o.payload->>'groupId'=(select gid::text from board) and o.status='pending'),(select count(*) from board_recipients),'only the individual intended recipients have pending corrections');
select api.worker_group_schedule_mail_payload(id) from app_private.email_outbox where payload->>'groupId'=(select gid::text from board) and status='pending';
select ok(not exists(select 1 from app_private.email_outbox where payload->>'groupId'=(select gid::text from board) and status='pending' and (message_type<>'group_schedule_corrected' or (payload->>'oldStartsAt')::timestamptz<>'2026-10-31T17:00Z' or (payload->>'startsAt')::timestamptz<>'2026-10-31T17:10Z')),'earlier SendGrid acceptance produces the exact old/new correction content');
select lives_ok($$select api.admin_live_planboard_publish('duindorp-halloween-2026',gid,snapshot->>'inputHash',schedule,(select revision from app_private.group_schedule_revisions where id=schedule),(select settings_version from app_private.events where id=eid),'planboard-replacement-publication-01') from board$$,'same publication retry returns its original receipt despite changed hash');
update board set preview=api.admin_live_planboard_preview('duindorp-halloween-2026','{"action":"undo","restoreKey":"published-draft-consent-01"}',app_private.live_planboard_hash(eid));
select is((select preview->>'requiresConfirmation' from board),'true','undo after publication requires a new reviewed draft and explicit publication');
select * from finish();
rollback;
