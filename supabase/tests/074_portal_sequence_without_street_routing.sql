begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);

-- Stored destinations and real opening/capacity settings, no street network.
update app_private.walking_edges set approved_at=null;
update app_private.walking_nodes set verified_at=null;
update app_private.start_points set walking_node_id=null,verified_at=null,version=version+1;
update app_private.portal_windows set opens_at='2026-10-31T14:00Z',closes_at='2026-10-31T22:00Z';
update app_private.event_route_settings set first_start_at='2026-10-31T15:00Z',global_ordinary_stop_at='2026-10-31T19:30Z',
  final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at='2026-10-31T18:00Z',
  finale_last_arrival_at='2026-10-31T20:30Z',finale_closes_at='2026-10-31T21:00Z',
  finale_available=true,planner_mode='dynamic';
do $$begin perform api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',
  (select version from app_private.start_points where id='20000000-0000-0000-0000-000000000001'));end $$;
select ok(app_private.start_point_safe_connection('20000000-0000-0000-0000-000000000001'),'confirmed saved start is usable for group assignment without nodes or edges');
select lives_ok($$select api.admin_startregie_move_group('23000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001','2026-10-31T16:30Z',
  (select version from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001'),
  'neutral','Synthetische groepsafspraak zonder straatrouting')$$,'real group assignment accepts a confirmed destination without a walking graph');
select cmp_ok((app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000001')->>'eligiblePortalCount')::integer,'>',0,
  'valid stored approved houses remain automatic sequence candidates without street connections');
select ok(not exists(select 1 from jsonb_array_elements(api.admin_startregie_snapshot('duindorp-halloween-2026')->'warnings') w
  where w->>'code'='WALKING_ROUTE_MISSING'),'the fresh server snapshot has no inapplicable walking-network task');
select lives_ok($$select api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',1,
  (select settings_version from app_private.events where slug='duindorp-halloween-2026'))$$,'group appointment confirms without street routing');
select ok(exists(select 1 from jsonb_array_elements(api.admin_startregie_snapshot('duindorp-halloween-2026')#>'{ops,routes,23000000-0000-0000-0000-000000000001,stops}') s
  where s->>'kind'='ordinary'),'confirmed appointment automatically has a private proposed house sequence');
select is(app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000001')->>'distanceMethod','straight_line','distance is explicitly a straight-line estimate');
select ok(not exists(select 1 from jsonb_array_elements(app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000001')->'stops') s
  where (s->>'walkMinutes')::integer<1),'estimated transfers never silently become zero minutes');
select lives_ok($$select api.admin_startregie_publish_times('duindorp-halloween-2026',
  array[(select current_schedule_revision_id from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001')],
  (select jsonb_build_array(jsonb_build_object('id',current_schedule_revision_id,'revision',1)) from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001'),
  (select settings_version from app_private.events where slug='duindorp-halloween-2026'),'no-street-publication-acceptance')$$,
  'explicit publication still succeeds without a street graph');
select is((select count(*)::integer from app_private.walking_edges where approved_at is not null),0,'planning and publication create no graph approvals');
select is((select count(*)::integer from app_private.walking_nodes where verified_at is not null),0,'planning and publication manufacture no verified nodes');
select is((select count(*)::integer from app_private.destination_estimate(null,4.26,52.1,4.26)),0,'missing source position is not a successful zero-time estimate');
select is((select count(*)::integer from app_private.destination_estimate(52.1,4.26,91,4.26)),0,'invalid destination is not a successful estimate');
select cmp_ok((select duration_seconds from app_private.destination_estimate(52.1,4.26,52.1,4.26)),'>=',60::bigint,'even coincident markers retain a nonzero planning allowance');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(api.group_snapshot('23000000-0000-0000-0000-000000000001')#>>'{group,start,address}',null::text,'authorized leader receives no first address before T minus sixty');
select is(api.group_snapshot('23000000-0000-0000-0000-000000000001')#>>'{group,start,coordinate}',null::text,'authorized leader receives no first marker before T minus sixty');
select ok(api.group_snapshot('23000000-0000-0000-0000-000000000001')#>>'{group,start,startsAt}' is not null,'published own start time is visible beforehand');
select ok(not (api.group_snapshot('23000000-0000-0000-0000-000000000001') ? 'ops'),'private sequence and candidate pool never enter the participant payload');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update app_private.start_points set private_address=null where id='20000000-0000-0000-0000-000000000001';
select is(app_private.start_point_readiness('20000000-0000-0000-0000-000000000001')->>'confirmationReason','START_POINT_ADDRESS_MISSING','a missing real address remains an actionable confirmation error');
select throws_ok($$select api.admin_startregie_confirm_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',(select version from app_private.start_points where id='20000000-0000-0000-0000-000000000001'))$$,'23514','START_POINT_ADDRESS_MISSING','a map position alone cannot confirm an addressless destination');
update app_private.portal_private_locations set marker_latitude=91,marker_longitude=4.27 where portal_id='12000000-0000-0000-0000-000000000030';
select ok(not exists(select 1 from jsonb_array_elements(app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000001')->'stops') stop where stop->>'kind'='finale'),'an invalid finale is not invented as a successful estimated destination');
select matches(app_private.start_ops_route_preview('23000000-0000-0000-0000-000000000001')->'warnings'->>0,'eindpoort','invalid finale explains which destination must be repaired');
select * from finish();
rollback;
