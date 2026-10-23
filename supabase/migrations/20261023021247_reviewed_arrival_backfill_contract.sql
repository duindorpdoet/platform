-- No historical rows are automatically changed by installing this contract.
-- An operator must review the preview and explicitly select bounded stop batches.
create or replace function app_private.arrival_backfill_candidates(_event_id uuid)
returns table(run_id uuid,stop_id uuid,participant_id uuid,child_id uuid,scan_id uuid,arrived_at timestamptz,actor_id uuid,eligible boolean,reason text)
language sql stable security definer set search_path='' as $$
 select r.id,s.id,rp.id,rc.child_id,e.id,s.completed_at,e.actor_id,
   e.id is not null and s.outcome in ('visited','mixed','all_skipped')
   and st.status in ('visited','skipped') and st.required_for_completion and st.exclusion_reason is null
   and rp.joined_at<=e.scanned_at and e.scanned_at<=s.completed_at
   and ((rp.attendance='present' and rp.departed_at is null) or (rp.attendance='departed' and rp.departed_at>s.completed_at))
   and coalesce((select m.party_id from app_private.together_memberships m where m.registration_id=reg.id and m.joined_at<=s.completed_at and (m.left_at is null or m.left_at>s.completed_at) order by m.joined_at desc limit 1),reg.id)
      is not distinct from app_private.poortenboek_team(_event_id,rc.child_id),
   case when e.id is null then 'no_confirmed_arrival'
    when s.outcome='system_skipped' then 'system_skip'
    when not st.required_for_completion or st.exclusion_reason is not null then 'historical_presence_uncertain'
    when rp.joined_at>e.scanned_at or e.scanned_at>s.completed_at or rp.attendance='absent' or (rp.attendance='departed' and rp.departed_at is null) or rp.departed_at<=s.completed_at then 'not_proven_present'
    when coalesce((select m.party_id from app_private.together_memberships m where m.registration_id=reg.id and m.joined_at<=s.completed_at and (m.left_at is null or m.left_at>s.completed_at) order by m.joined_at desc limit 1),reg.id)
      is distinct from app_private.poortenboek_team(_event_id,rc.child_id) then 'historical_team_uncertain'
    else 'confirmed_scan_and_historical_presence' end
 from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id
 join app_private.walking_groups g on g.id=r.group_id and g.event_id=_event_id
 join app_private.stop_participant_statuses st on st.run_stop_id=s.id
 join app_private.run_participants rp on rp.id=st.run_participant_id and rp.run_id=r.id
 join app_private.registration_children rc on rc.id=rp.registration_child_id
 join app_private.registrations reg on reg.id=rc.registration_id
 left join app_private.scan_evidence e on e.run_stop_id=s.id
 where s.state='completed' and not exists(select 1 from app_private.poortenboek_passport_seals p where p.event_id=_event_id and p.child_id=rc.child_id and p.run_stop_id=s.id)
$$;
revoke all on function app_private.arrival_backfill_candidates(uuid) from public,anon,authenticated;

create or replace function api.redesign_arrival_backfill(_actor uuid,_event_slug text,_stop_ids uuid[] default null,_apply boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare eventid uuid; stopid uuid; inserted_count integer:=0;
begin
 select id into eventid from app_private.events where slug=_event_slug;
 if _actor is null or eventid is null or not app_private.has_capability(eventid,'event_admin',_actor) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _apply then
  if coalesce(cardinality(_stop_ids),0) not between 1 and 100 then raise exception 'BOUNDED_REVIEW_REQUIRED'; end if;
  -- Lock selected runs so the decision cannot race a live roster update.
  perform r.id from app_private.group_runs r join app_private.run_stops s on s.run_id=r.id join app_private.walking_groups g on g.id=r.group_id
    where s.id=any(_stop_ids) and g.event_id=eventid order by r.id for update of r;
  insert into app_private.run_stop_arrivals(event_id,run_id,run_stop_id,run_participant_id,child_id,scan_evidence_id,arrived,arrived_at,actor_id,source)
  select eventid,c.run_id,c.stop_id,c.participant_id,c.child_id,c.scan_id,true,c.arrived_at,c.actor_id,'reviewed_backfill'
  from app_private.arrival_backfill_candidates(eventid) c where c.stop_id=any(_stop_ids) and c.eligible on conflict do nothing;
  get diagnostics inserted_count=row_count;
  for stopid in select distinct c.run_stop_id from app_private.run_stop_arrivals c where c.event_id=eventid and c.run_stop_id=any(_stop_ids) and c.source='reviewed_backfill' loop
   perform app_private.record_arrival_seals(stopid);
  end loop;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
  values(eventid,_actor,'redesign.arrival_backfill','event',eventid,jsonb_build_object('insertedArrivals',inserted_count,'reviewedStops',_stop_ids));
 end if;
 return jsonb_build_object('applied',_apply,'insertedArrivals',inserted_count,
  'candidates',coalesce((select jsonb_agg(to_jsonb(c) order by c.stop_id,c.child_id) from app_private.arrival_backfill_candidates(eventid) c),'[]'::jsonb));
end $$;
revoke all on function api.redesign_arrival_backfill(uuid,text,uuid[],boolean) from public,anon,authenticated;
grant execute on function api.redesign_arrival_backfill(uuid,text,uuid[],boolean) to service_role;
