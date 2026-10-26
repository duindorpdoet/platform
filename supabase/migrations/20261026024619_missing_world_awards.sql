-- Canonical world collection is separate from physical visits and story progress.
create table app_private.world_coverage_policies (
 event_id uuid not null references app_private.events(id),version integer not null,
 missing_worlds text[] not null,fingerprint text not null,created_at timestamptz not null default clock_timestamp(),
 primary key(event_id,version)
);
create table app_private.child_world_awards (
 event_id uuid not null references app_private.events(id),child_id uuid not null references app_private.children(id),
 world_slug text not null check(world_slug in ('heksenrijk','dodenrijk','circuswereld','besmette-zone','geestenwereld','vampierrijk')),
 origin text not null check(origin in ('themed','compensation')),run_stop_id uuid not null references app_private.run_stops(id),
 run_participant_id uuid not null references app_private.run_participants(id),policy_version integer not null,
 reason text not null check(reason in ('arrival','last_accepted_stop','route_settlement','own_departure','evening_completed')),
 awarded_at timestamptz not null default clock_timestamp(),primary key(event_id,child_id,world_slug),
 foreign key(event_id,policy_version) references app_private.world_coverage_policies(event_id,version),
 foreign key(run_stop_id,run_participant_id) references app_private.run_stop_arrivals(run_stop_id,run_participant_id)
);
create index child_world_awards_stop on app_private.child_world_awards(run_stop_id,run_participant_id);
alter table app_private.world_coverage_policies enable row level security;
alter table app_private.child_world_awards enable row level security;
revoke all on app_private.world_coverage_policies,app_private.child_world_awards from public,anon,authenticated;

create function app_private.refresh_world_coverage(_event uuid) returns integer language plpgsql security definer set search_path='' as $$
declare missing text[]; last_policy app_private.world_coverage_policies; fingerprint text; next_version integer;
begin
 perform pg_advisory_xact_lock(hashtextextended(_event::text||':world-coverage',0));
 select coalesce(array_agg(required.world_slug order by required.world_slug),'{}'::text[]) into missing from unnest(array['heksenrijk','dodenrijk','circuswereld','besmette-zone','geestenwereld','vampierrijk']) required(world_slug)
 where not exists(select 1 from app_private.portals p join app_private.worlds w on w.id=p.world_id and w.slug=required.world_slug
  join app_private.events e on e.id=p.event_id
  where p.event_id=_event and p.approval_status='approved' and p.lifecycle_status='active' and app_private.portal_location_ready(p.id)
  and exists(select 1 from app_private.portal_windows win where win.portal_id=p.id and win.opens_at<win.closes_at and win.max_concurrent_groups>0 and win.max_children_per_visit>0 and win.closes_at-win.opens_at>=make_interval(mins=>win.visit_minutes)
    and win.opens_at<(e.local_date+time '21:30') at time zone 'Europe/Amsterdam' and win.closes_at>(e.local_date+time '16:30') at time zone 'Europe/Amsterdam'));
 fingerprint:=md5(missing::text);
 select * into last_policy from app_private.world_coverage_policies where event_id=_event order by version desc limit 1;
 if last_policy.fingerprint=fingerprint then return last_policy.version; end if;
 next_version:=coalesce(last_policy.version,0)+1;
 insert into app_private.world_coverage_policies(event_id,version,missing_worlds,fingerprint) values(_event,next_version,missing,fingerprint);
 return next_version;
end $$;
revoke all on function app_private.refresh_world_coverage(uuid) from public,anon,authenticated;

create function app_private.award_missing_worlds(_event uuid,_child uuid,_stop uuid,_participant uuid,_all boolean,_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare policy integer; source_world text; chosen text; missing text[]; count_awards integer:=0;
begin
 -- Lock each child's collection so concurrent scans cannot choose the same next world.
 perform pg_advisory_xact_lock(hashtextextended(_event::text||':'||_child::text||':world-awards',0));
 if not exists(select 1 from app_private.run_stop_arrivals a join app_private.run_participants rp on rp.id=a.run_participant_id and rp.attendance='present' and rp.departed_at is null
  join app_private.group_runs active_run on active_run.id=rp.run_id and active_run.status in ('live','paused')
  join app_private.registration_children rc on rc.id=rp.registration_child_id and rc.child_id=_child and rc.participation_status='active'
  join app_private.registrations reg on reg.id=rc.registration_id and reg.status='submitted'
  where a.event_id=_event and a.run_stop_id=_stop and a.run_participant_id=_participant and a.child_id=_child and a.arrived) then return; end if;
 select w.slug into source_world from app_private.run_stops s left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id join app_private.portals p on p.id=coalesce(s.portal_id,ps.portal_id) join app_private.worlds w on w.id=p.world_id where s.id=_stop;
 policy:=app_private.refresh_world_coverage(_event);
 if source_world=any(array['heksenrijk','dodenrijk','circuswereld','besmette-zone','geestenwereld','vampierrijk']) then
  insert into app_private.child_world_awards(event_id,child_id,world_slug,origin,run_stop_id,run_participant_id,policy_version,reason) values(_event,_child,source_world,'themed',_stop,_participant,policy,'arrival') on conflict do nothing;
  return;
 end if;
 if source_world<>'anders' or exists(select 1 from app_private.run_stops where id=_stop and stop_kind='finale') then return; end if;
 -- A retry for the same arrival must never draw another random reward.
 if not _all and exists(select 1 from app_private.child_world_awards where event_id=_event and child_id=_child and run_stop_id=_stop and origin='compensation') then return; end if;
 select missing_worlds into missing from app_private.world_coverage_policies where event_id=_event and version=policy;
 for chosen in select candidate.world_slug from unnest(missing) candidate(world_slug) where not exists(select 1 from app_private.child_world_awards a where a.event_id=_event and a.child_id=_child and a.world_slug=candidate.world_slug) and not exists(select 1 from app_private.poortenboek_passport_seals seal join app_private.worlds w on w.id=seal.world_id where seal.event_id=_event and seal.child_id=_child and w.slug=candidate.world_slug) order by random() loop
  insert into app_private.child_world_awards(event_id,child_id,world_slug,origin,run_stop_id,run_participant_id,policy_version,reason) values(_event,_child,chosen,'compensation',_stop,_participant,policy,_reason) on conflict do nothing;
  count_awards:=count_awards+1;exit when not _all;
 end loop;
 if count_awards>0 then
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(_event,auth.uid(),'world.compensation','child',_child,jsonb_build_object('runStopId',_stop,'count',count_awards,'policyVersion',policy,'reason',_reason));
 end if;
end $$;
revoke all on function app_private.award_missing_worlds(uuid,uuid,uuid,uuid,boolean,text) from public,anon,authenticated;

create function app_private.settle_child_worlds(_participant uuid,_reason text) returns void language plpgsql security definer set search_path='' as $$
declare a app_private.run_stop_arrivals; rp app_private.run_participants;
begin
 select * into rp from app_private.run_participants where id=_participant and attendance='present' and departed_at is null for update;
 if rp.id is null then return; end if;
 if _reason='route_settlement' and (not exists(select 1 from app_private.live_route_visits v join app_private.group_runs r on r.group_id=v.group_id and r.id=rp.run_id where v.source='manual' and v.retired_at is null)
  or exists(select 1 from app_private.live_route_visits v join app_private.group_runs r on r.group_id=v.group_id and r.id=rp.run_id join app_private.portals p on p.id=v.portal_id join app_private.worlds w on w.id=p.world_id and w.slug='anders' where v.kind='ordinary' and v.retired_at is null and (v.run_stop_id is null or exists(select 1 from app_private.run_stops future where future.id=v.run_stop_id and future.state<>'completed' and not exists(select 1 from app_private.run_stop_arrivals arrived where arrived.run_stop_id=future.id and arrived.run_participant_id=rp.id and arrived.arrived))))) then return; end if;
 select arrival.* into a from app_private.run_stop_arrivals arrival join app_private.run_stops s on s.id=arrival.run_stop_id left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id join app_private.portals p on p.id=coalesce(s.portal_id,ps.portal_id) join app_private.worlds w on w.id=p.world_id and w.slug='anders'
 where arrival.run_participant_id=rp.id and arrival.arrived order by arrival.arrived_at desc,arrival.run_stop_id limit 1;
 if a.run_stop_id is not null then perform app_private.award_missing_worlds(a.event_id,a.child_id,a.run_stop_id,rp.id,true,_reason); end if;
end $$;
revoke all on function app_private.settle_child_worlds(uuid,text) from public,anon,authenticated;

create function app_private.world_award_arrival() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.arrived then
  perform app_private.award_missing_worlds(new.event_id,new.child_id,new.run_stop_id,new.run_participant_id,false,'arrival');
  perform app_private.settle_child_worlds(new.run_participant_id,'route_settlement');
 end if;
 return new;
end $$;
revoke all on function app_private.world_award_arrival() from public,anon,authenticated;
create trigger world_award_arrival after insert or update of arrived on app_private.run_stop_arrivals for each row execute function app_private.world_award_arrival();

create function app_private.world_award_departure() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.attendance='present' and old.departed_at is null and (new.attendance='departed' or new.departed_at is not null) then perform app_private.settle_child_worlds(old.id,'own_departure'); end if;
 return new;
end $$;
revoke all on function app_private.world_award_departure() from public,anon,authenticated;
create trigger world_award_departure before update of attendance,departed_at on app_private.run_participants for each row execute function app_private.world_award_departure();

create function app_private.world_award_finish() returns trigger language plpgsql security definer set search_path='' as $$
declare participant uuid;
begin
 if new.status='completed' and old.status<>'completed' then
  for participant in select id from app_private.run_participants where run_id=old.id and attendance='present' and departed_at is null loop perform app_private.settle_child_worlds(participant,'evening_completed');end loop;
 end if;
 return new;
end $$;
revoke all on function app_private.world_award_finish() from public,anon,authenticated;
create trigger world_award_finish before update of status on app_private.group_runs for each row execute function app_private.world_award_finish();

create function app_private.world_coverage_changed() returns trigger language plpgsql security definer set search_path='' as $$
declare eid uuid;
begin
 if tg_table_name='portals' then eid:=case when tg_op='DELETE' then old.event_id else new.event_id end;
 else select event_id into eid from app_private.portals where id=case when tg_op='DELETE' then old.portal_id else new.portal_id end; end if;
 if eid is not null then perform app_private.refresh_world_coverage(eid); end if;
 return null;
end $$;
revoke all on function app_private.world_coverage_changed() from public,anon,authenticated;
create trigger world_coverage_portals after insert or update of world_id,approval_status,lifecycle_status or delete on app_private.portals for each row execute function app_private.world_coverage_changed();
create trigger world_coverage_windows after insert or update or delete on app_private.portal_windows for each row execute function app_private.world_coverage_changed();

create function app_private.world_route_settlement() returns trigger language plpgsql security definer set search_path='' as $$
declare participant uuid;
begin
 for participant in select rp.id from app_private.run_participants rp join app_private.group_runs r on r.id=rp.run_id where r.group_id=new.group_id and rp.attendance='present' and rp.departed_at is null loop perform app_private.settle_child_worlds(participant,'route_settlement'); end loop;
 return null;
end $$;
revoke all on function app_private.world_route_settlement() from public,anon,authenticated;
-- Runs once per accepted plan revision, after all visits have moved atomically.
create trigger world_route_settlement after update of version on app_private.live_route_plans for each row execute function app_private.world_route_settlement();

alter function app_private.poortenboek_snapshot(app_private.poortenboek_sessions) rename to poortenboek_snapshot_before_world_collection;
revoke all on function app_private.poortenboek_snapshot_before_world_collection(app_private.poortenboek_sessions) from public,anon,authenticated;
create function app_private.poortenboek_snapshot(_session app_private.poortenboek_sessions) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; code app_private.poortenboek_codes; collection jsonb;
begin
 result:=app_private.poortenboek_snapshot_before_world_collection(_session);
 select * into code from app_private.poortenboek_codes where id=_session.code_id;
 select coalesce(jsonb_agg(item order by item->>'earnedAt',item->>'slug'),'[]') into collection from (
  select jsonb_build_object('slug',a.world_slug,'name',w.name,'origin',a.origin,'earnedAt',a.awarded_at,'stopId',a.run_stop_id,'policyVersion',a.policy_version) item
  from app_private.child_world_awards a join app_private.worlds w on w.event_id=a.event_id and w.slug=a.world_slug where a.event_id=code.event_id and a.child_id=code.child_id
  union all
  select distinct on(w.slug) jsonb_build_object('slug',w.slug,'name',w.name,'origin','themed','earnedAt',seal.earned_at,'stopId',seal.run_stop_id,'policyVersion',null)
  from app_private.poortenboek_passport_seals seal join app_private.worlds w on w.id=seal.world_id
  where seal.event_id=code.event_id and seal.child_id=code.child_id and w.slug in ('heksenrijk','dodenrijk','circuswereld','besmette-zone','geestenwereld','vampierrijk')
   and not exists(select 1 from app_private.child_world_awards a where a.event_id=code.event_id and a.child_id=code.child_id and a.world_slug=w.slug)
 ) collected;
 result:=jsonb_set(result,'{worlds}',coalesce((select jsonb_agg(world||jsonb_build_object('unlocked',coalesce((world->>'unlocked')::boolean,false) or exists(select 1 from jsonb_array_elements(collection) award where award->>'slug'=world->>'slug'))) from jsonb_array_elements(result->'worlds') world where world->>'slug'<>'anders'),'[]'));
 return result||jsonb_build_object('worldCollection',collection,
 'missingWorlds',coalesce((select to_jsonb(missing_worlds) from app_private.world_coverage_policies where event_id=code.event_id order by version desc limit 1),'[]'));
end $$;
revoke all on function app_private.poortenboek_snapshot(app_private.poortenboek_sessions) from public,anon,authenticated;
create trigger world_coverage_location after insert or update or delete on app_private.portal_private_locations for each row execute function app_private.world_coverage_changed();
-- Initialize policy only; historical child/visit records remain untouched.
do $$ declare eid uuid;begin for eid in select id from app_private.events loop perform app_private.refresh_world_coverage(eid);end loop;end $$;

alter function api.admin_live_planboard_snapshot(text) rename to admin_live_planboard_snapshot_before_worlds;
revoke all on function api.admin_live_planboard_snapshot_before_worlds(text) from public,anon,authenticated;
create function api.admin_live_planboard_snapshot(_event_slug text) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; missing text[]; notices jsonb;
begin
 result:=api.admin_live_planboard_snapshot_before_worlds(_event_slug);
 select missing_worlds into missing from app_private.world_coverage_policies where event_id=(result->>'eventId')::uuid order by version desc limit 1;
 if cardinality(missing)>0 then
  select coalesce(jsonb_agg(jsonb_build_object('code','MISSING_WORLD_CANDY_ROUTE','severity','warning','message','Ontbrekende werelden: '||array_to_string(missing,', ')||'. Plan een echte stop bij Anders via de bezoekdetails; zonder geschikte aankomst zijn geen bonuszegels mogelijk.','visitIds','[]'::jsonb,'groupIds',jsonb_build_array(g->>'id'))),'[]') into notices
  from jsonb_array_elements(result->'groups') g where not exists(select 1 from jsonb_array_elements(result->'visits') v join app_private.portals p on p.id=(v->>'portalId')::uuid join app_private.worlds w on w.id=p.world_id and w.slug='anders' where v->>'groupId'=g->>'id' and v->>'kind'='ordinary' and v->>'status'<>'skipped');
  result:=result||jsonb_build_object('warnings',(result->'warnings')||notices,'missingWorlds',to_jsonb(missing));
 end if;
 return result;
end $$;
revoke all on function api.admin_live_planboard_snapshot(text) from public,anon;
grant execute on function api.admin_live_planboard_snapshot(text) to authenticated;
