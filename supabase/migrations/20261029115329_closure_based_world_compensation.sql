-- Freeze compensation when the HOUSE channel closes, independent of participant registration.
-- Retain existing awards and their historical policy versions. Deployment changes no settings/routes.
alter table app_private.world_coverage_policies
 add column policy_status text not null default 'retired'
  check(policy_status in ('provisional','active','pending','retired')),
 add column source_fingerprint text,
 add column activated_at timestamptz,
 add column activated_by uuid references auth.users(id),
 add column activation_reason text;
create unique index world_coverage_one_active on app_private.world_coverage_policies(event_id) where policy_status='active';
create unique index world_coverage_one_pending on app_private.world_coverage_policies(event_id) where policy_status='pending';
create unique index world_coverage_one_provisional on app_private.world_coverage_policies(event_id) where policy_status='provisional';

create function app_private.world_coverage_missing_now(_event uuid) returns text[]
language sql stable security definer set search_path='' as $$
 select coalesce(array_agg(required.slug order by required.slug),'{}'::text[])
 from unnest(array['heksenrijk','dodenrijk','circuswereld','besmette-zone','geestenwereld','vampierrijk']) required(slug)
 where not exists(
  select 1 from app_private.portals p join app_private.worlds w on w.id=p.world_id and w.slug=required.slug
  join app_private.events e on e.id=p.event_id
  left join app_private.event_route_settings settings on settings.event_id=e.id
  -- Operation pause is deliberately excluded: a temporary pause does not change event coverage.
  where p.event_id=_event and p.approval_status='approved' and p.lifecycle_status='active'
   and app_private.portal_location_ready(p.id)
   and exists(select 1 from app_private.portal_windows win where win.portal_id=p.id
    and win.max_concurrent_groups>0 and win.max_children_per_visit>0
    and win.opens_at<win.closes_at
    and greatest(win.opens_at,coalesce(settings.first_start_at,(e.local_date+time '16:30') at time zone 'Europe/Amsterdam'))
      +make_interval(mins=>win.visit_minutes+win.buffer_minutes)
     <=least(win.closes_at,coalesce(settings.global_ordinary_stop_at,(e.local_date+time '21:30') at time zone 'Europe/Amsterdam'))));
$$;
revoke all on function app_private.world_coverage_missing_now(uuid) from public,anon,authenticated;

create or replace function app_private.refresh_world_coverage(_event uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare missing text[]; current_policy app_private.world_coverage_policies;
 candidate app_private.world_coverage_policies; fingerprint text; next_version integer; houses_open boolean; next_status text;
begin
 perform pg_advisory_xact_lock(hashtextextended(_event::text||':world-coverage',0));
 select coalesce((settings->>'portalRegistrationOpen')::boolean,true) into houses_open from app_private.events where id=_event;
 if houses_open is null then return null; end if;
 missing:=app_private.world_coverage_missing_now(_event);
 fingerprint:=md5(missing::text);
 select * into current_policy from app_private.world_coverage_policies where event_id=_event and policy_status='active';
 if houses_open then
  -- Reopening makes coverage provisional again; earned awards remain untouched.
  update app_private.world_coverage_policies set policy_status='retired' where event_id=_event and policy_status in ('active','pending');
  next_status:='provisional';
 elsif current_policy.version is null then
  next_status:='active';
 elsif current_policy.source_fingerprint=fingerprint then
  update app_private.world_coverage_policies set policy_status='retired' where event_id=_event and policy_status='pending';
  return current_policy.version;
 else
  -- Late approvals, withdrawals or theme/window/location edits need an explicit review.
  next_status:='pending';
 end if;
 select * into candidate from app_private.world_coverage_policies where event_id=_event and policy_status=next_status;
 if candidate.source_fingerprint=fingerprint then return candidate.version; end if;
 update app_private.world_coverage_policies set policy_status='retired' where event_id=_event and policy_status in ('provisional','pending');
 select coalesce(max(version),0)+1 into next_version from app_private.world_coverage_policies where event_id=_event;
 insert into app_private.world_coverage_policies(event_id,version,missing_worlds,fingerprint,source_fingerprint,policy_status,activated_at,activated_by,activation_reason)
 values(_event,next_version,missing,md5(next_status||':'||fingerprint),fingerprint,next_status,
  case when next_status='active' then clock_timestamp() end,
  case when next_status='active' then auth.uid() end,
  case when next_status='active' then 'Definitief huizenaanbod bij gesloten huisinschrijving' end);
 if next_status in ('active','pending') then
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
  values(_event,auth.uid(),'world.coverage.'||next_status,'event',_event,
   jsonb_build_object('policyVersion',next_version,'missingWorlds',missing,'previousPolicyVersion',current_policy.version));
 end if;
 return case when next_status='pending' then current_policy.version else next_version end;
end $$;
revoke all on function app_private.refresh_world_coverage(uuid) from public,anon,authenticated;

create function app_private.world_coverage_current_version(_event uuid) returns integer
language sql stable security definer set search_path='' as $$
 select p.version from app_private.world_coverage_policies p join app_private.events e on e.id=p.event_id
 where p.event_id=_event and p.policy_status=case when coalesce((e.settings->>'portalRegistrationOpen')::boolean,true) then 'provisional' else 'active' end;
$$;
revoke all on function app_private.world_coverage_current_version(uuid) from public,anon,authenticated;
create function app_private.world_coverage_missing(_event uuid) returns text[]
language sql stable security definer set search_path='' as $$
 select coalesce((select missing_worlds from app_private.world_coverage_policies where event_id=_event
  and version=app_private.world_coverage_current_version(_event)),'{}'::text[]);
$$;
revoke all on function app_private.world_coverage_missing(uuid) from public,anon,authenticated;

create function app_private.world_coverage_registration_changed() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if coalesce((new.settings->>'portalRegistrationOpen')::boolean,true)
  is distinct from coalesce((old.settings->>'portalRegistrationOpen')::boolean,true) then
  perform app_private.refresh_world_coverage(new.id);
 end if;
 return null;
end $$;
revoke all on function app_private.world_coverage_registration_changed() from public,anon,authenticated;
create trigger world_coverage_registration_changed after update of settings on app_private.events
 for each row execute function app_private.world_coverage_registration_changed();

create function app_private.world_coverage_projection(_event uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('portalRegistrationOpen',coalesce((e.settings->>'portalRegistrationOpen')::boolean,true),
  'status',case when coalesce((e.settings->>'portalRegistrationOpen')::boolean,true) then 'provisional' else 'active' end,
  'policyVersion',p.version,'missingWorlds',coalesce(to_jsonb(p.missing_worlds),'[]'::jsonb),
  'worldNames',coalesce((select jsonb_object_agg(w.slug,w.name) from app_private.worlds w where w.event_id=e.id),'{}'::jsonb),
  'pendingRevision',(select jsonb_build_object('version',c.version,'missingWorlds',c.missing_worlds,'fingerprint',c.source_fingerprint,'createdAt',c.created_at)
   from app_private.world_coverage_policies c where c.event_id=e.id and c.policy_status='pending'),
  'canRevise',app_private.has_capability(e.id,'event_admin',auth.uid()) or app_private.has_capability(e.id,'portals_manage',auth.uid()))
 from app_private.events e left join app_private.world_coverage_policies p on p.event_id=e.id and p.version=app_private.world_coverage_current_version(e.id)
 where e.id=_event;
$$;
revoke all on function app_private.world_coverage_projection(uuid) from public,anon,authenticated;

create function api.admin_world_coverage_snapshot(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare eid uuid;
begin
 select id into eid from app_private.events where slug=_event_slug;
 if eid is null or not(app_private.has_capability(eid,'event_admin',auth.uid()) or app_private.has_capability(eid,'portals_manage',auth.uid())
  or app_private.has_capability(eid,'groups_manage',auth.uid()) or app_private.has_capability(eid,'live_support',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return app_private.world_coverage_projection(eid);
end $$;
revoke all on function api.admin_world_coverage_snapshot(text) from public,anon;
grant execute on function api.admin_world_coverage_snapshot(text) to authenticated;

create function api.admin_accept_world_coverage_revision(_event_slug text,_expected_version integer,_expected_fingerprint text,_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid; pending app_private.world_coverage_policies; active_version integer;
begin
 select id into eid from app_private.events where slug=_event_slug for update;
 if eid is null or not(app_private.has_capability(eid,'event_admin',auth.uid()) or app_private.has_capability(eid,'portals_manage',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if char_length(trim(coalesce(_reason,''))) not between 10 and 500 or _expected_version is null or _expected_version<1
  or coalesce(_expected_fingerprint,'')!~'^[0-9a-f]{32}$' then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(eid::text||':world-coverage',0));
 if coalesce((select (settings->>'portalRegistrationOpen')::boolean from app_private.events where id=eid),true) then raise exception 'WORLD_COVERAGE_PROVISIONAL' using errcode='23514'; end if;
 perform app_private.refresh_world_coverage(eid);
 -- Repeating an already accepted exact revision is safe, without another audit or version.
 if exists(select 1 from app_private.world_coverage_policies where event_id=eid and version=_expected_version and policy_status='active' and source_fingerprint=_expected_fingerprint) then return app_private.world_coverage_projection(eid); end if;
 select * into pending from app_private.world_coverage_policies where event_id=eid and policy_status='pending';
 if pending.version is null or pending.version is distinct from _expected_version or pending.source_fingerprint is distinct from _expected_fingerprint then raise exception 'STALE_WORLD_COVERAGE' using errcode='40001'; end if;
 select version into active_version from app_private.world_coverage_policies where event_id=eid and policy_status='active';
 update app_private.world_coverage_policies set policy_status='retired' where event_id=eid and policy_status='active';
 update app_private.world_coverage_policies set policy_status='active',activated_at=clock_timestamp(),activated_by=auth.uid(),activation_reason=trim(_reason)
  where event_id=eid and version=pending.version;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(eid,auth.uid(),'world.coverage.accepted','event',eid,jsonb_build_object('fromVersion',active_version,'toVersion',pending.version,'missingWorlds',pending.missing_worlds,'reason',trim(_reason)));
 return app_private.world_coverage_projection(eid);
end $$;
revoke all on function api.admin_accept_world_coverage_revision(text,integer,text,text) from public,anon;
grant execute on function api.admin_accept_world_coverage_revision(text,integer,text,text) to authenticated;

-- Legacy fixed plans identify their finale by the final position. Dynamic plans
-- identify it explicitly; the configured finale is never an ordinary candy stop.
create function app_private.world_compensation_ordinary_stop(_stop uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce((s.stop_kind='ordinary' or (s.stop_kind is null and ps.position<(
  select max(last_stop.position) from app_private.route_plan_stops last_stop where last_stop.plan_version_id=ps.plan_version_id)))
  and coalesce(s.portal_id,ps.portal_id) is distinct from settings.final_portal_id,false)
 from app_private.run_stops s left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id
 join app_private.group_runs r on r.id=s.run_id join app_private.walking_groups g on g.id=r.group_id
 join app_private.event_route_settings settings on settings.event_id=g.event_id where s.id=_stop;
$$;
revoke all on function app_private.world_compensation_ordinary_stop(uuid) from public,anon,authenticated;

create or replace function app_private.award_missing_worlds(_event uuid,_child uuid,_stop uuid,_participant uuid,_all boolean,_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare policy integer; source_world text; chosen text; missing text[]; count_awards integer:=0;
begin
 -- Lock each child's collection so concurrent scans cannot choose the same next world.
 perform pg_advisory_xact_lock(hashtextextended(_event::text||':'||_child::text||':world-awards',0));
 if not exists(select 1 from app_private.run_stop_arrivals a join app_private.run_participants rp on rp.id=a.run_participant_id and rp.attendance='present' and rp.departed_at is null
  join app_private.group_runs active_run on active_run.id=rp.run_id and active_run.status in ('live','paused')
  join app_private.registration_children rc on rc.id=rp.registration_child_id and rc.child_id=_child and rc.participation_status='active'
  join app_private.registrations reg on reg.id=rc.registration_id and reg.status='submitted'
  where a.event_id=_event and a.run_id=rp.run_id and a.run_stop_id=_stop and a.run_participant_id=_participant and a.child_id=_child and a.arrived) then return; end if;
 select w.slug into source_world from app_private.run_stops s left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id join app_private.portals p on p.id=coalesce(s.portal_id,ps.portal_id) join app_private.worlds w on w.id=p.world_id where s.id=_stop;
 policy:=app_private.world_coverage_current_version(_event);
 if policy is null then return; end if;
 if source_world=any(array['heksenrijk','dodenrijk','circuswereld','besmette-zone','geestenwereld','vampierrijk']) then
  insert into app_private.child_world_awards(event_id,child_id,world_slug,origin,run_stop_id,run_participant_id,policy_version,reason) values(_event,_child,source_world,'themed',_stop,_participant,policy,'arrival') on conflict do nothing;
  return;
 end if;
 if coalesce((select (settings->>'portalRegistrationOpen')::boolean from app_private.events where id=_event),true) then return; end if;
 if source_world is distinct from 'anders' or not coalesce(app_private.world_compensation_ordinary_stop(_stop),false) then return; end if;
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

create or replace function app_private.settle_child_worlds(_participant uuid,_reason text) returns void language plpgsql security definer set search_path='' as $$
declare a app_private.run_stop_arrivals; rp app_private.run_participants;
begin
 select * into rp from app_private.run_participants where id=_participant and attendance='present' and departed_at is null for update;
 if rp.id is null then return; end if;
 if _reason='route_settlement' and (not exists(select 1 from app_private.live_route_visits v join app_private.group_runs r on r.group_id=v.group_id and r.id=rp.run_id where v.source='manual' and v.retired_at is null)
  or exists(select 1 from app_private.live_route_visits v join app_private.group_runs r on r.group_id=v.group_id and r.id=rp.run_id join app_private.portals p on p.id=v.portal_id join app_private.worlds w on w.id=p.world_id and w.slug='anders' where v.kind='ordinary' and v.retired_at is null and (v.run_stop_id is null or exists(select 1 from app_private.run_stops future where future.id=v.run_stop_id and future.state<>'completed' and not exists(select 1 from app_private.run_stop_arrivals arrived where arrived.run_stop_id=future.id and arrived.run_participant_id=rp.id and arrived.arrived))))) then return; end if;
 select arrival.* into a from app_private.run_stop_arrivals arrival join app_private.run_stops s on s.id=arrival.run_stop_id left join app_private.route_plan_stops ps on ps.id=s.plan_stop_id join app_private.portals p on p.id=coalesce(s.portal_id,ps.portal_id) join app_private.worlds w on w.id=p.world_id and w.slug='anders'
 where arrival.run_participant_id=rp.id and arrival.arrived and s.run_id=rp.run_id and app_private.world_compensation_ordinary_stop(s.id) order by arrival.arrived_at desc,arrival.run_stop_id limit 1;
 if a.run_stop_id is not null then perform app_private.award_missing_worlds(a.event_id,a.child_id,a.run_stop_id,rp.id,true,_reason); end if;
end $$;
revoke all on function app_private.settle_child_worlds(uuid,text) from public,anon,authenticated;


-- Existing closed events receive one real active policy; no channel is opened or closed here.
do $$ declare eid uuid; begin
 for eid in select id from app_private.events order by id loop perform app_private.refresh_world_coverage(eid); end loop;
end $$;

-- Keep the same private passport projection and expose only the applicable policy metadata.
alter function app_private.poortenboek_snapshot(app_private.poortenboek_sessions) rename to poortenboek_snapshot_before_closure_policy;
revoke all on function app_private.poortenboek_snapshot_before_closure_policy(app_private.poortenboek_sessions) from public,anon,authenticated;
create function app_private.poortenboek_snapshot(_session app_private.poortenboek_sessions) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; eid uuid; coverage jsonb;
begin
 result:=app_private.poortenboek_snapshot_before_closure_policy(_session);
 select event_id into eid from app_private.poortenboek_codes where id=_session.code_id;
 coverage:=app_private.world_coverage_projection(eid);
 return result||jsonb_build_object('missingWorlds',coverage->'missingWorlds',
  'worldCoverage',jsonb_build_object('status',coverage->'status','policyVersion',coverage->'policyVersion','missingWorlds',coverage->'missingWorlds'));
end $$;
revoke all on function app_private.poortenboek_snapshot(app_private.poortenboek_sessions) from public,anon,authenticated;
