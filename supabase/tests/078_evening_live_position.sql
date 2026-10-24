begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table position_test(event_id uuid,group_id uuid,pub_id uuid,run_id uuid,stop_id uuid,version integer,portal_id uuid,source_node uuid,portal_node uuid,parent_before jsonb);
insert into position_test(event_id,group_id) select event_id,id from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001';
grant all on position_test to authenticated;
update app_private.portal_windows set opens_at=now()-interval '1 hour',closes_at=now()+interval '5 hours';
update app_private.start_slots set starts_at=now()-interval '1 minute';
update app_private.event_route_settings set first_start_at=now()-interval '2 hours',global_ordinary_stop_at=now()+interval '2 hours',
 allowed_personal_stop_times=array[now()+interval '1 hour'],ordinary_visit_seconds=60,route_buffer_seconds=0,
 final_portal_id='12000000-0000-0000-0000-000000000030',finale_opens_at=now()-interval '1 hour',finale_last_arrival_at=now()+interval '4 hours',
 finale_closes_at=now()+interval '5 hours',finale_show_seconds=60,finale_turnover_seconds=120,finale_max_concurrent_groups=10,finale_max_concurrent_children=40,finale_available=true,planner_mode='dynamic'
 where event_id=(select event_id from position_test);
with inserted as (insert into app_private.group_schedule_revisions(group_id,revision,state,start_slot_id,effective_ordinary_stop_at,expected_finale_arrival_at,preference_match,published_at)
 select group_id,1,'published',g.start_slot_id,now()+interval '2 hours',now()+interval '1 hour','neutral',now() from position_test t join app_private.walking_groups g on g.id=t.group_id returning id)
 update app_private.walking_groups wg set route_mode='dynamic',current_schedule_revision_id=inserted.id,desired_ordinary_visits=2,version=version+1 from inserted where wg.id=(select group_id from position_test);
update position_test set pub_id=(select id from app_private.group_start_publications where group_id=position_test.group_id and schedule_id is not null order by publication_order desc limit 1);
select is(app_private.evening_route_context((select group_id from position_test))->>'mode','preview','before presence the route remains a preparation');
select is((app_private.evening_route_context((select group_id from position_test))->>'calculatedFromAt')::timestamptz,(select starts_at from app_private.group_start_publications where id=(select pub_id from position_test)),'preparation uses the exact frozen appointment instant');
select ok((select point_snapshot#>'{walking_node_snapshot,coordinate}' is not null from app_private.group_start_publications where id=(select pub_id from position_test)),'new publication freezes its actual walking-node coordinate');
select is(app_private.frozen_walking_source((select event_id from position_test),null,null,null),null::uuid,'missing source never becomes an arbitrary walking node');
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select throws_ok($$select app_private.evening_route_context(group_id) from position_test$$,'42501',null,'participant cannot enumerate the private planning context');
update position_test set run_id=(api.run_start(group_id,array(select (v->>'registrationChildId')::uuid from jsonb_array_elements(api.group_roster(group_id)) v),
 (api.group_snapshot(group_id)#>>'{group,version}')::integer,'position-real-start','position-real-start')->>'runId')::uuid;
update position_test set parent_before=api.group_snapshot(group_id),stop_id=(api.group_snapshot(group_id)#>>'{run,currentStop,id}')::uuid,version=(api.group_snapshot(group_id)#>>'{run,version}')::integer,portal_id=(api.group_snapshot(group_id)#>>'{run,currentStop,portal,id}')::uuid;
set local role postgres;
update position_test set source_node=(app_private.evening_route_context(group_id)->>'sourceNodeId')::uuid,portal_node=(select walking_node_id from app_private.run_stop_location_snapshots where run_stop_id=position_test.stop_id);
select is((select count(*)::integer from app_private.run_stop_location_snapshots where run_id=(select run_id from position_test)),1,'release stores one location snapshot for the one disclosed stop');
select is(app_private.evening_route_context((select group_id from position_test))->>'mode','live','actual presence switches the route to live computation');
select ok((app_private.evening_route_context((select group_id from position_test))->>'calculatedFromAt')::timestamptz>=(select (parent_before#>>'{group,start,startsAt}')::timestamptz+interval '30 seconds' from position_test),'live calculation uses actual server time instead of the old start instant');
select is(app_private.evening_route_context((select group_id from position_test))#>>'{currentStop,id}',(select stop_id::text from position_test),'live context retains the already-released stop ID');
select throws_ok($$update app_private.run_stop_location_snapshots set longitude=longitude+.001 where run_stop_id=(select stop_id from position_test)$$,'55000','RELEASED_LOCATION_IMMUTABLE','released location cannot be edited in place');
select throws_ok($$update app_private.run_stops set portal_id='12000000-0000-0000-0000-000000000004' where id=(select stop_id from position_test)$$,'55000','RELEASED_STOP_IDENTITY_IMMUTABLE','pending stop ID cannot be rebound to a different physical portal');
-- Editing a working start point cannot move the run's frozen departure source.
update app_private.start_points set name='Gewijzigd concept naast de publicatie',walking_node_id=(select id from app_private.walking_nodes where portal_id='12000000-0000-0000-0000-000000000030' limit 1)
 where id=(select (point_snapshot->>'id')::uuid from app_private.group_start_publications where id=(select pub_id from position_test));
select is((app_private.evening_route_context((select group_id from position_test))->>'sourceNodeId')::uuid,(select source_node from position_test),'working point edits do not rewrite the live departure source');
-- Move the current portal after release: preserve the parent's disclosed address
-- and do not invent a new confirmed physical position at that new marker.
update app_private.portal_private_locations set street='Een later gewijzigd adres',marker_longitude=coalesce(marker_longitude,geocoded_longitude,longitude)+.01,
 marker_latitude=coalesce(marker_latitude,geocoded_latitude,latitude) where portal_id=(select portal_id from position_test);
update app_private.walking_nodes set coordinate=point(coordinate[0]+.01,coordinate[1]) where id=(select portal_node from position_test);
set local role authenticated;
select is(api.group_snapshot((select group_id from position_test))#>>'{run,currentStop,portal,address}',(select parent_before#>>'{run,currentStop,portal,address}' from position_test),'portal editor cannot silently move the address already disclosed on the phone');
select is(api.group_snapshot((select group_id from position_test))#>'{run,currentStop,portal,coordinate}',(select parent_before#>'{run,currentStop,portal,coordinate}' from position_test),'phone retains the released coordinate');
select is(api.group_snapshot((select group_id from position_test))#>>'{run,currentStop,id}',(select stop_id::text from position_test),'marker change preserves stop ID and pending-command scope');
set local role postgres;
select is(app_private.evening_route_context((select group_id from position_test))#>>'{currentStop,address}',(select parent_before#>>'{run,currentStop,portal,address}' from position_test),'organization context uses the same released address');
select is(app_private.evening_route_context((select group_id from position_test))->>'remainingSourceNodeId',null::text,'moved node is not used as the future origin for the old physical location');
set local role authenticated;
select lives_ok($$select api.run_arrive_and_advance(run_id,stop_id,version,'TEST-PORTAL-01-TOKEN',
 (select jsonb_object_agg(p->>'id','skipped') from jsonb_array_elements(api.group_snapshot(group_id)#>'{run,participants}') p),'position-real-arrival') from position_test$$,
 'actual arrival remains durable when the next verified walking origin needs review');
select is(api.group_snapshot((select group_id from position_test))#>>'{run,status}','paused','unknown safe continuation pauses new assignment');
select is(api.group_snapshot((select group_id from position_test))#>'{run,currentStop}','null'::jsonb,'no replacement address is invented');
select is(api.group_snapshot((select group_id from position_test))#>>'{run,planningConflict}','NO_SAFE_FINALE_PATH','parent receives an explicit organization-review state');
set local role postgres;
select is((select count(*)::integer from app_private.run_stop_arrivals where run_id=(select run_id from position_test)),1,'confirmed actual arrival survives the blocked next route');
select is((select count(*)::integer from app_private.poortenboek_passport_seals where run_id=(select run_id from position_test)),1,'outside child retains the normal actual-arrival seal');
select is(app_private.evening_route_context((select group_id from position_test))->>'lastConfirmedStopId',(select stop_id::text from position_test),'source identity remains the last actual completed scan');
select is(app_private.evening_route_context((select group_id from position_test))->>'lastConfirmedPortalId',(select portal_id::text from position_test),'historical physical portal identity is unchanged');
select is(app_private.evening_route_context((select group_id from position_test))->>'sourceNodeId',null::text,'no fabricated origin replaces an unavailable frozen walking source');
-- A later unscanned system skip is history, never a position or counted visit.
insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count)
 select event_id,'12000000-0000-0000-0000-000000000003',group_id,run_id,'ordinary','cancelled',now(),now()+interval '5 minutes',1 from position_test;
insert into app_private.run_stops(run_id,portal_id,reservation_id,stop_kind,sequence,state,outcome,opened_at,completed_at)
 select t.run_id,'12000000-0000-0000-0000-000000000003',b.id,'ordinary',2,'completed','system_skipped',now(),now() from position_test t join app_private.portal_reservations b on b.run_id=t.run_id and b.portal_id='12000000-0000-0000-0000-000000000003';
select is(app_private.evening_route_context((select group_id from position_test))->>'lastConfirmedPortalId',(select portal_id::text from position_test),'unscanned system skip cannot become a fictitious route position');
select is(app_private.evening_route_context((select group_id from position_test))->>'completedOrdinaryVisits','1','unscanned system skip does not consume the ordinary-visit count');
select is(jsonb_array_length(app_private.evening_route_context((select group_id from position_test))->'history'),2,'actual and system history remain separately visible');
create temp table retained_position as select md5(jsonb_agg(to_jsonb(a) order by a.run_stop_id,a.run_participant_id)::text) arrivals from app_private.run_stop_arrivals a;
-- Restore the verified historical walking node, then resume through a real
-- leader action and trusted worker. Original arrival evidence is not replayed.
update app_private.walking_nodes n set coordinate=point(s.node_longitude::double precision,s.node_latitude::double precision)
 from app_private.run_stop_location_snapshots s where s.run_stop_id=(select stop_id from position_test) and n.id=s.walking_node_id;
-- Moving a node correctly revoked its verification and edge approvals. A repair
-- must explicitly restore those synthetic proofs, not merely its coordinates.
update app_private.walking_nodes set verified_at=clock_timestamp(),verified_by='f0000000-0000-0000-0000-000000000001' where id=(select portal_node from position_test);
update app_private.walking_edges set approved_at=clock_timestamp(),approved_by='f0000000-0000-0000-0000-000000000001'
 where event_id=(select event_id from position_test) and (from_node_id=(select portal_node from position_test) or to_node_id=(select portal_node from position_test));

select is((app_private.evening_route_context((select group_id from position_test))->>'sourceNodeId')::uuid,(select portal_node from position_test),'verified walking origin can be recovered without rewriting history');
set local role authenticated;
select lives_ok($$select api.run_set_state(run_id,'live',(api.group_snapshot(group_id)#>>'{run,version}')::integer,'Groepsleider hervat na herstel van de gecontroleerde wandelroute') from position_test$$,'leader can resume after the controlled route repair');
set local role service_role;
select lives_ok($$select api.worker_dispatch_due_groups('duindorp-halloween-2026',50)$$,'trusted dispatch uses the repaired confirmed position');
set local role postgres;
select is((select coalesce(s.portal_id,p.portal_id) from app_private.group_runs r join app_private.run_stops s on s.id=r.current_stop_id left join app_private.route_plan_stops p on p.id=s.plan_stop_id where r.id=(select run_id from position_test)),
 '12000000-0000-0000-0000-000000000002'::uuid,'new assignment continues from the true prior house without revisiting it');
select is((select md5(jsonb_agg(to_jsonb(a) order by a.run_stop_id,a.run_participant_id)::text) from app_private.run_stop_arrivals a),(select arrivals from retained_position),'resume and replanning preserve exact historical arrival IDs and content');
select is((select count(*)::integer from app_private.run_stop_location_snapshots where run_id=(select run_id from position_test)),2,'only genuinely released destinations receive a location snapshot');
select ok(not has_table_privilege('authenticated','app_private.run_stop_location_snapshots','select'),'private released-location archive cannot enumerate another group');
select * from finish();
rollback;
