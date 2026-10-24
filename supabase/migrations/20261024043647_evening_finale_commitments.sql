-- Additive, immutable publication commitments. Existing publications and runtime
-- bookings are not backfilled or moved by this migration.
alter table app_private.group_runs add column start_publication_id uuid references app_private.group_start_publications(id) on delete restrict;
create index group_runs_start_publication_fk on app_private.group_runs(start_publication_id) where start_publication_id is not null;
alter table app_private.portal_reservations add column start_publication_id uuid references app_private.group_start_publications(id) on delete restrict;
create unique index portal_reservation_finale_publication on app_private.portal_reservations(start_publication_id) where start_publication_id is not null;
alter table app_private.portal_reservations add constraint reservation_publication_is_finale check(start_publication_id is null or kind='finale');
create table app_private.finale_publication_commitments (
 publication_id uuid primary key references app_private.group_start_publications(id) on delete restrict,
 event_id uuid not null references app_private.events(id) on delete restrict,
 group_id uuid not null references app_private.walking_groups(id) on delete restrict,
 portal_id uuid not null references app_private.portals(id) on delete restrict,
 reserved_arrival_at timestamptz not null,
 service_until timestamptz not null,
 occupied_until timestamptz not null,
 grace_seconds integer not null check(grace_seconds>=0),
 planned_children integer not null check(planned_children>0),
 safe_waiting_instruction text not null,
 configuration_snapshot jsonb not null,
 created_at timestamptz not null default clock_timestamp(),
 check(service_until>reserved_arrival_at and occupied_until>=service_until)
);
create index finale_commitment_event_fk on app_private.finale_publication_commitments(event_id);
create index finale_commitment_group_fk on app_private.finale_publication_commitments(group_id);
create index finale_commitment_portal_fk on app_private.finale_publication_commitments(portal_id);
alter table app_private.finale_publication_commitments enable row level security;
revoke all on app_private.finale_publication_commitments from public,anon,authenticated;

create or replace function app_private.preserve_finale_commitment()
returns trigger language plpgsql set search_path='' as $function$
begin raise exception 'PUBLISHED_FINALE_IMMUTABLE' using errcode='55000'; end;
$function$;
create trigger preserve_finale_commitment before update or delete on app_private.finale_publication_commitments
for each row execute function app_private.preserve_finale_commitment();

create or replace function app_private.assess_finale_reservation(
 _event_id uuid,_group_id uuid,_portal_id uuid,_arrival timestamptz,_until timestamptz,_children integer,_decision_at timestamptz
) returns jsonb language plpgsql stable security definer set search_path='' as $function$
declare cfg app_private.event_route_settings; codes jsonb:='[]'; reasons jsonb:='[]'; peak_groups integer:=0; peak_children integer:=0;
begin
 select * into cfg from app_private.event_route_settings where event_id=_event_id;
 if cfg.event_id is null or not cfg.finale_available or cfg.final_portal_id is distinct from _portal_id
  or not exists(select 1 from app_private.portals p where p.id=_portal_id and p.event_id=_event_id
    and p.approval_status='approved' and p.lifecycle_status='active' and p.operation_status in ('open','scheduled'))
  or not app_private.portal_has_verified_walking_connection(_portal_id) then
   codes:=codes||'"FINALE_UNAVAILABLE"'::jsonb;reasons:=reasons||'"De gepubliceerde finale is niet beschikbaar; organisatiecontrole is nodig."'::jsonb;
 end if;
 if _children is null or _children<=0 then codes:=codes||'"EMPTY_GROUP"'::jsonb;reasons:=reasons||'"Er zijn geen aanwezige kinderen."'::jsonb; end if;
 if _arrival is null or _until is null or _arrival<cfg.finale_opens_at or _arrival>cfg.finale_last_arrival_at or _until>cfg.finale_closes_at or _until<=_arrival then
  codes:=codes||'"FINALE_WINDOW_CONFLICT"'::jsonb;reasons:=reasons||'"De gereserveerde finale past niet in het geldige ontvangstvenster."'::jsonb;
 end if;
 with latest_runs as materialized (
  select distinct on(r.group_id) r.* from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id
  where g.event_id=_event_id order by r.group_id,r.created_at desc,r.id desc
 ), latest_publications as materialized (
  select distinct on(p.group_id) p.group_id,p.id from app_private.group_start_publications p
   where p.event_id=_event_id order by p.group_id,p.publication_order desc
 ), bookings as materialized (
  select b.group_id,b.reserved_from,b.reserved_until,b.child_count
  from app_private.portal_reservations b
  left join latest_runs r on r.group_id=b.group_id
  left join latest_publications p on p.group_id=b.group_id
  where b.event_id=_event_id and b.portal_id=_portal_id and b.kind='finale' and b.status in ('held','active')
    and b.group_id<>_group_id and (b.expires_at is null or b.expires_at>_decision_at)
    and ((b.run_id is not null and r.id=b.run_id and r.status in ('ready','live','paused'))
      or (b.run_id is null and b.start_publication_id=p.id and (coalesce(r.status::text,'') not in ('completed','stopped') or p.id is distinct from app_private.run_start_publication(r.id)))
      or (b.run_id is null and b.start_publication_id is null and coalesce(r.status::text,'') not in ('completed','stopped')))
    and b.reserved_from<_until and b.reserved_until>_arrival
 ), ticks as (select _arrival at_time union select reserved_from from bookings where reserved_from>_arrival and reserved_from<_until),
 per_group as (select t.at_time,b.group_id,max(b.child_count) children from ticks t join bookings b on b.reserved_from<=t.at_time and b.reserved_until>t.at_time group by t.at_time,b.group_id),
 totals as (select at_time,count(*)::integer groups,sum(children)::integer children from per_group group by at_time)
 select coalesce(max(groups),0)+1,coalesce(max(children),0)+_children into peak_groups,peak_children from totals;
 if peak_groups>cfg.finale_max_concurrent_groups or peak_children>cfg.finale_max_concurrent_children then
  codes:=codes||'"FINALE_CAPACITY_EXCEEDED"'::jsonb;reasons:=reasons||'"De vaste finale-afspraak heeft onvoldoende beschikbare ontvangstcapaciteit."'::jsonb;
 end if;
 return jsonb_build_object('eligible',jsonb_array_length(codes)=0,'blockingCodes',codes,'reasons',reasons,
  'peakGroups',peak_groups,'peakChildren',peak_children,'maxGroups',cfg.finale_max_concurrent_groups,'maxChildren',cfg.finale_max_concurrent_children);
end;
$function$;

create or replace function app_private.ensure_finale_commitment(_publication_id uuid)
returns uuid language plpgsql security definer set search_path='' as $function$
declare p app_private.group_start_publications; s app_private.group_schedule_revisions; cfg app_private.event_route_settings;
 c app_private.finale_publication_commitments; children integer; arrival timestamptz; until_at timestamptz; assessment jsonb; safe_instruction text;
begin
 select * into p from app_private.group_start_publications where id=_publication_id;
 if p.id is null then return null; end if;
 perform app_private.lock_evening_event(p.event_id);
 select * into c from app_private.finale_publication_commitments where publication_id=p.id;
 if c.publication_id is not null then return c.publication_id; end if;
 -- A legacy departure without a published finale instant is never turned into
 -- an invented appointment based solely on the opening time.
 if p.schedule_id is null then return null; end if;
 select * into s from app_private.group_schedule_revisions where id=p.schedule_id and group_id=p.group_id and state in ('published','superseded');
 if s.id is null or s.expected_finale_arrival_at is null then raise exception 'FINAL_RESERVATION_REQUIRED' using errcode='23514'; end if;
 if exists(select 1 from app_private.group_runs r where r.group_id=p.group_id and r.status in ('live','paused')
   and coalesce(r.start_publication_id,app_private.run_start_publication(r.id)) is distinct from p.id) then raise exception 'JOURNEY_ALREADY_STARTED' using errcode='23514'; end if;
 select * into cfg from app_private.event_route_settings where event_id=p.event_id;
 arrival:=s.expected_finale_arrival_at;
 until_at:=arrival+make_interval(secs=>cfg.finale_show_seconds+cfg.finale_turnover_seconds);
 select count(*) into children from app_private.group_registrations a join app_private.registration_children rc
   on rc.registration_id=a.registration_id and rc.participation_status='active' where a.group_id=p.group_id and a.superseded_at is null;
 assessment:=app_private.assess_finale_reservation(p.event_id,p.group_id,cfg.final_portal_id,arrival,until_at,children,clock_timestamp());
 if not (assessment->>'eligible')::boolean then raise exception '%',assessment#>>'{blockingCodes,0}' using errcode='23514',detail=(assessment->'reasons')::text; end if;
 safe_instruction:=case when nullif(trim(cfg.finale_waiting_area),'') is not null or nullif(trim(cfg.finale_safe_approach),'') is not null
   then concat_ws(' ',case when nullif(trim(cfg.finale_waiting_area),'') is not null then 'Wacht samen op de afgesproken plek: '||trim(cfg.finale_waiting_area)||'.' end,
    case when nullif(trim(cfg.finale_safe_approach),'') is not null then 'Volg deze afgesproken aanloop: '||trim(cfg.finale_safe_approach)||'.' end)
   else 'Blijf bij jullie groep en vraag de organisatie waar jullie veilig kunnen wachten.' end;
 insert into app_private.finale_publication_commitments(publication_id,event_id,group_id,portal_id,reserved_arrival_at,service_until,occupied_until,grace_seconds,planned_children,safe_waiting_instruction,configuration_snapshot)
  values(p.id,p.event_id,p.group_id,cfg.final_portal_id,arrival,arrival+make_interval(secs=>cfg.finale_show_seconds),until_at,cfg.finale_turnover_seconds,children,safe_instruction,to_jsonb(cfg));
 insert into app_private.portal_reservations(event_id,portal_id,group_id,kind,status,reserved_from,service_until,reserved_until,child_count,start_publication_id)
  values(p.event_id,cfg.final_portal_id,p.group_id,'finale','held',arrival,arrival+make_interval(secs=>cfg.finale_show_seconds),until_at,children,p.id);
 -- A distinct publication can supersede a not-yet-used appointment; never touch
 -- a reservation already bound to a live or historic run.
 update app_private.portal_reservations set status='cancelled',cancelled_reason='Vervangen door een expliciete nieuwe publicatie',version=version+1
  where group_id=p.group_id and kind='finale' and run_id is null and status in ('held','active') and start_publication_id is distinct from p.id;
 return p.id;
end;
$function$;

create or replace function app_private.capture_finale_commitment()
returns trigger language plpgsql security definer set search_path='' as $function$
begin perform app_private.ensure_finale_commitment(new.id);return new;end;
$function$;
create trigger capture_finale_commitment after insert on app_private.group_start_publications
for each row execute function app_private.capture_finale_commitment();

create or replace function app_private.run_start_publication(_run_id uuid)
returns uuid language sql stable security definer set search_path='' as $function$
 select coalesce(r.start_publication_id,(select p.id from app_private.group_start_publications p
  where p.group_id=r.group_id and (r.schedule_revision_id is null or p.schedule_id=r.schedule_revision_id)
   and p.published_at<=coalesce(r.started_at,r.created_at)
  order by p.publication_order desc limit 1)) from app_private.group_runs r where r.id=_run_id
$function$;

create or replace function app_private.try_reserve_finale(_run_id uuid,_earliest_arrival timestamptz,_decision_at timestamptz)
returns uuid language plpgsql security definer set search_path='' as $function$
declare r app_private.group_runs; g app_private.walking_groups; c app_private.finale_publication_commitments;
 b app_private.portal_reservations; p uuid; children integer; assessment jsonb;
begin
 select g1.* into g from app_private.group_runs r1 join app_private.walking_groups g1 on g1.id=r1.group_id where r1.id=_run_id;
 perform app_private.lock_evening_event(g.event_id);
 select * into r from app_private.group_runs where id=_run_id for update;
 if r.id is null or r.status not in ('live','paused') then return null; end if;
 p:=app_private.run_start_publication(r.id);
 if p is null then return null; end if;
 perform app_private.ensure_finale_commitment(p);
 select * into c from app_private.finale_publication_commitments where publication_id=p;
 if c.publication_id is null or _earliest_arrival>c.reserved_arrival_at+make_interval(secs=>c.grace_seconds) then return null; end if;
 select count(*) into children from app_private.run_participants rp where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null;
 assessment:=app_private.assess_finale_reservation(g.event_id,g.id,c.portal_id,c.reserved_arrival_at,c.occupied_until,children,_decision_at);
 if not (assessment->>'eligible')::boolean then return null; end if;
 select * into b from app_private.portal_reservations where start_publication_id=p for update;
 if b.id is null or b.status not in ('held','active') or (b.run_id is not null and b.run_id<>r.id)
   or exists(select 1 from app_private.portal_reservations other where other.run_id=r.id and other.kind='finale' and other.status in ('held','active') and other.id<>b.id)
   then return null; end if;
 if b.run_id is distinct from r.id or b.child_count<>children then
  update app_private.portal_reservations set run_id=r.id,child_count=children,version=version+1 where id=b.id returning * into b;
 end if;
 if r.start_publication_id is null then update app_private.group_runs set start_publication_id=p where id=r.id; end if;
 return b.id;
end;
$function$;

create or replace function app_private.assert_finale_arrival_window(_run_id uuid,_stop_id uuid)
returns void language plpgsql security definer set search_path='' as $function$
declare s app_private.run_stops; b app_private.portal_reservations; grace integer; decision_at timestamptz:=clock_timestamp();
begin
 select * into s from app_private.run_stops where id=_stop_id and run_id=_run_id;
 if s.stop_kind::text is distinct from 'finale' then return; end if;
 -- A previously accepted real scan is still evidence when completion/retry
 -- happens after the admission window. It cannot become a second arrival.
 if exists(select 1 from app_private.scan_evidence e where e.run_stop_id=s.id) then return; end if;
 select * into b from app_private.portal_reservations where id=s.reservation_id and run_id=_run_id and kind='finale' and status='active';
 if b.id is null then raise exception 'FINAL_RESERVATION_REQUIRED' using errcode='23514'; end if;
 select c.grace_seconds into grace from app_private.finale_publication_commitments c where c.publication_id=b.start_publication_id;
 if grace is null then select cfg.finale_turnover_seconds into grace from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id join app_private.event_route_settings cfg on cfg.event_id=g.event_id where r.id=_run_id;end if;
 if decision_at<b.reserved_from then raise exception 'FINAL_ARRIVAL_TOO_EARLY' using errcode='23514'; end if;
 if decision_at>b.reserved_from+make_interval(secs=>coalesce(grace,120)) then raise exception 'FINAL_RESERVATION_MISSED' using errcode='23514'; end if;
end;
$function$;

revoke all on function app_private.preserve_finale_commitment(),app_private.assess_finale_reservation(uuid,uuid,uuid,timestamptz,timestamptz,integer,timestamptz),
 app_private.ensure_finale_commitment(uuid),app_private.capture_finale_commitment(),app_private.run_start_publication(uuid),
 app_private.try_reserve_finale(uuid,timestamptz,timestamptz),app_private.assert_finale_arrival_window(uuid,uuid) from public,anon,authenticated;

create or replace function app_private.validate_finale_publication_reservation()
returns trigger language plpgsql security definer set search_path='' as $function$
declare c app_private.finale_publication_commitments; assessment jsonb;
begin
 if tg_op='UPDATE' and old.start_publication_id is not null and new.start_publication_id is distinct from old.start_publication_id then raise exception 'FINAL_RESERVATION_SCOPE_CONFLICT' using errcode='23514';end if;
 if new.start_publication_id is null then return new; end if;
 select * into c from app_private.finale_publication_commitments where publication_id=new.start_publication_id;
 if c.publication_id is null or row(c.event_id,c.group_id,c.portal_id,c.reserved_arrival_at,c.service_until,c.occupied_until)
   is distinct from row(new.event_id,new.group_id,new.portal_id,new.reserved_from,new.service_until,new.reserved_until)
   or (new.run_id is not null and not exists(select 1 from app_private.group_runs r where r.id=new.run_id and r.group_id=c.group_id
     and app_private.run_start_publication(r.id)=c.publication_id))
  then raise exception 'FINAL_RESERVATION_SCOPE_CONFLICT' using errcode='23514'; end if;
 if new.status not in ('held','active') then return new; end if;
 perform app_private.lock_evening_event(new.event_id);
 if tg_op='UPDATE' and new.child_count<=old.child_count and new.run_id is not distinct from old.run_id then return new; end if;
 assessment:=app_private.assess_finale_reservation(new.event_id,new.group_id,new.portal_id,new.reserved_from,new.reserved_until,new.child_count,clock_timestamp());
 if not (assessment->>'eligible')::boolean then raise exception '%',assessment#>>'{blockingCodes,0}' using errcode='23514',detail=(assessment->'reasons')::text;end if;
 return new;
end;
$function$;
create trigger evening_finale_publication_reservation before insert or update on app_private.portal_reservations
for each row execute function app_private.validate_finale_publication_reservation();

create or replace function app_private.run_finale_details(_run_id uuid,_decision_at timestamptz)
returns jsonb language plpgsql stable security definer set search_path='' as $function$
declare r app_private.group_runs; g app_private.walking_groups; p app_private.group_start_publications;
 c app_private.finale_publication_commitments; b app_private.portal_reservations; source_node uuid; target_node uuid;
 children integer; step_free boolean; metrics record; assessment jsonb; problem text; earliest timestamptz;
begin
 select * into r from app_private.group_runs where id=_run_id;
 select * into g from app_private.walking_groups where id=r.group_id;
 select * into p from app_private.group_start_publications where id=app_private.run_start_publication(r.id);
 select * into c from app_private.finale_publication_commitments where publication_id=p.id;
 if c.publication_id is null then return jsonb_build_object('eligible',false,'code','FINAL_RESERVATION_REQUIRED');end if;
 select * into b from app_private.portal_reservations where start_publication_id=p.id;
 select count(*) into children from app_private.run_participants rp where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null;
 select exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id
  join app_private.children child on child.id=rc.child_id where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null and nullif(trim(child.accessibility_note),'') is not null) into step_free;
 select node.id into source_node from app_private.run_stops stop
  left join app_private.route_plan_stops old_stop on old_stop.id=stop.plan_stop_id
  join app_private.walking_nodes node on node.portal_id=coalesce(stop.portal_id,old_stop.portal_id) and node.event_id=g.event_id and node.verified_at is not null
  where stop.run_id=r.id and stop.state='completed' and exists(select 1 from app_private.scan_evidence e where e.run_stop_id=stop.id)
  order by stop.sequence desc,node.id limit 1;
 source_node:=coalesce(source_node,(p.point_snapshot->>'walking_node_id')::uuid);
 select node.id into target_node from app_private.walking_nodes node where node.portal_id=c.portal_id and node.event_id=g.event_id and node.verified_at is not null order by node.id limit 1;
 select * into metrics from app_private.walking_path_metrics(g.event_id,source_node,target_node,step_free);
 earliest:=_decision_at+make_interval(secs=>metrics.duration_seconds::integer);
 assessment:=app_private.assess_finale_reservation(g.event_id,g.id,c.portal_id,c.reserved_arrival_at,c.occupied_until,children,_decision_at);
 if metrics.duration_seconds is null then problem:='NO_SAFE_FINALE_PATH';
 elsif earliest>c.reserved_arrival_at+make_interval(secs=>c.grace_seconds) then problem:='FINAL_RESERVATION_MISSED';
 elsif not (assessment->>'eligible')::boolean then problem:=assessment#>>'{blockingCodes,0}';
 elsif b.id is null or b.status not in ('held','active') or (b.run_id is not null and b.run_id<>r.id)
  or exists(select 1 from app_private.portal_reservations other where other.run_id=r.id and other.kind='finale' and other.status in ('held','active') and other.id<>b.id) then problem:='FINAL_RESERVATION_CONFLICT';
 end if;
 return jsonb_build_object('eligible',problem is null,'code',problem,'publicationId',p.id,'revision',p.revision,
  'reservationId',b.id,'reservedArrivalAt',c.reserved_arrival_at,'waitingUntil',c.reserved_arrival_at-make_interval(secs=>metrics.duration_seconds::integer),
  'safeWaitingInstruction',c.safe_waiting_instruction,'walkSeconds',metrics.duration_seconds,'sourceNodeId',source_node,'portalId',c.portal_id,
  'earliestArrivalAt',earliest,'graceSeconds',c.grace_seconds,'capacity',assessment);
end;
$function$;

create or replace function app_private.pause_for_finale_conflict(_run_id uuid,_code text,_decision_at timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare g app_private.walking_groups; message text;
begin
 select wg.* into g from app_private.group_runs r join app_private.walking_groups wg on wg.id=r.group_id where r.id=_run_id;
 message:=case _code when 'FINAL_RESERVATION_MISSED' then 'De vaste finale-afspraak is niet meer haalbaar. Blijf bij jullie groep en vraag de organisatie om herplanning.'
  when 'FINAL_RESERVATION_REQUIRED' then 'Er ontbreekt een geldige gepubliceerde finale-afspraak. Vraag de organisatie om hulp.'
  else 'De finale-afspraak moet door de organisatie worden gecontroleerd. Blijf bij jullie groep en vraag om hulp.' end;
 update app_private.group_runs set status='paused',version=version+1 where id=_run_id and status='live';
 insert into app_private.route_alerts(event_id,group_id,run_id,priority,code,message)
  select g.event_id,g.id,_run_id,'urgent',_code,message where not exists(select 1 from app_private.route_alerts where run_id=_run_id and code=_code and status='open');
 insert into app_private.dispatch_decisions(event_id,run_id,sequence,decision,input_snapshot,candidate_summary,reason)
  select g.event_id,_run_id,coalesce(max(d.sequence),0)+1,'wait',jsonb_build_object('decidedAt',_decision_at,'planningConflict',_code),'[]',message
  from app_private.dispatch_decisions d where d.run_id=_run_id;
 return jsonb_build_object('decision','wait','paused',true,'planningConflict',_code,'safeWaitingInstruction',message);
end;
$function$;
revoke all on function app_private.validate_finale_publication_reservation(),app_private.run_finale_details(uuid,timestamptz),app_private.pause_for_finale_conflict(uuid,text,timestamptz) from public,anon,authenticated;

create or replace function app_private.validate_run_start_publication()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
 if tg_op='UPDATE' and old.start_publication_id is not null and new.start_publication_id is distinct from old.start_publication_id then
  raise exception 'RUN_START_PUBLICATION_IMMUTABLE' using errcode='55000';
 end if;
 if new.start_publication_id is not null and not exists(select 1 from app_private.group_start_publications p
  join app_private.walking_groups g on g.id=new.group_id and g.event_id=p.event_id
  where p.id=new.start_publication_id and p.group_id=new.group_id) then
  raise exception 'RUN_START_PUBLICATION_SCOPE_CONFLICT' using errcode='23514';
 end if;
 return new;
end;
$function$;
create trigger evening_run_start_publication before insert or update of start_publication_id,group_id on app_private.group_runs
for each row execute function app_private.validate_run_start_publication();
revoke all on function app_private.validate_run_start_publication() from public,anon,authenticated;

CREATE OR REPLACE FUNCTION api.run_start(_group_id uuid, _present_registration_child_ids uuid[], _expected_group_version integer, _idempotency_key text, _request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  group_record app_private.walking_groups;
  schedule app_private.group_schedule_revisions;
  plan_id uuid;
  v_run_id uuid;
  first_stop_id uuid;
  receipt app_private.command_receipts;
  dispatch_result jsonb;
  publication app_private.group_start_publications;
  result jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_group_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.walking_groups evening_group where evening_group.id=_group_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':run.start:' || _idempotency_key, 0));
  select * into receipt from app_private.command_receipts
  where actor_id = actor and command_type = 'run.start' and idempotency_key = _idempotency_key;
  if receipt.id is not null then
    if receipt.request_hash <> _request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '23505'; end if;
    if not app_private.is_current_leader(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
    return receipt.safe_result;
  end if;
  perform 1 from app_private.events where id=(select event_id from app_private.walking_groups where id=_group_id) for no key update;
  select * into group_record from app_private.walking_groups where id = _group_id for update;
  if group_record.id is null or group_record.version <> _expected_group_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if not app_private.is_current_leader(_group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(cardinality(_present_registration_child_ids), 0) = 0 then raise exception 'EMPTY_GROUP' using errcode = '23514'; end if;
  if exists (
    select 1 from unnest(_present_registration_child_ids) supplied(id)
    where not exists (
      select 1 from app_private.registration_children registration_child
      join app_private.group_registrations assignment on assignment.registration_id = registration_child.registration_id
      where registration_child.id = supplied.id and assignment.group_id = _group_id
        and assignment.superseded_at is null and registration_child.participation_status = 'active'
    )
  ) then raise exception 'INVALID_ROSTER' using errcode = '23514'; end if;

  if group_record.route_mode = 'dynamic' then
    select * into schedule from app_private.group_schedule_revisions
    where group_id = group_record.id and state = 'published'
    order by revision desc limit 1;
    if schedule.id is null then raise exception 'SCHEDULE_NOT_PUBLISHED' using errcode = '23514'; end if;
    select * into publication from app_private.group_start_publications where group_id=group_record.id and schedule_id=schedule.id order by publication_order desc limit 1;
    if publication.id is null then raise exception 'SCHEDULE_NOT_PUBLISHED' using errcode='23514';end if;
    if clock_timestamp() < publication.starts_at then
      raise exception 'START_TIME_NOT_REACHED' using errcode = '23514';
    end if;
    if exists (
      select 1 from app_private.group_registrations assignment
      join app_private.registrations registration on registration.id = assignment.registration_id and registration.status = 'submitted'
      left join app_private.payment_requests payment on payment.registration_id = registration.id
      where assignment.group_id = _group_id and assignment.superseded_at is null
        and coalesce(payment.status::text, '') not in ('confirmed', 'waived')
    ) then raise exception 'PAYMENT_NOT_CONFIRMED' using errcode = '23514'; end if;
    insert into app_private.group_runs(group_id, active_plan_version_id, schedule_revision_id, status, started_at,start_publication_id)
    values (_group_id, null, schedule.id, 'live', clock_timestamp(),publication.id) returning id into v_run_id;
  else
    select id into plan_id from app_private.route_plan_versions
    where group_id = _group_id and state = 'published' order by revision desc limit 1;
    if plan_id is null then raise exception 'ROUTE_NOT_PUBLISHED' using errcode = '23514'; end if;
  if not exists(select 1 from app_private.group_start_publications where group_id=_group_id) then
    raise exception 'SCHEDULE_NOT_PUBLISHED' using errcode='23514'; end if;
  if clock_timestamp() < (select starts_at from app_private.group_start_publications where group_id=_group_id
    order by publication_order desc limit 1) then raise exception 'START_TIME_NOT_REACHED' using errcode='23514'; end if;

    select * into publication from app_private.group_start_publications where group_id=_group_id order by publication_order desc limit 1;
    if publication.point_snapshot->>'walking_node_id' is not null and not exists(
      select 1 from app_private.route_plan_stops stop join app_private.walking_nodes node on node.portal_id=stop.portal_id and node.event_id=group_record.event_id and node.verified_at is not null
      cross join lateral app_private.walking_path_metrics(group_record.event_id,(publication.point_snapshot->>'walking_node_id')::uuid,node.id,false) safe_path
      where stop.plan_version_id=plan_id and stop.position=1) then raise exception 'NO_SAFE_WALKING_PATH' using errcode='23514'; end if;
    insert into app_private.group_runs(group_id, active_plan_version_id, status, started_at,start_publication_id)
    values (_group_id, plan_id, 'live', clock_timestamp(),publication.id) returning id into v_run_id;
  end if;

  insert into app_private.run_participants(run_id, registration_child_id, attendance)
  select v_run_id, registration_child.id,
    case when registration_child.id = any(_present_registration_child_ids)
      then 'present'::app_private.attendance_status else 'absent'::app_private.attendance_status end
  from app_private.registration_children registration_child
  join app_private.group_registrations assignment on assignment.registration_id = registration_child.registration_id
  where assignment.group_id = _group_id and assignment.superseded_at is null
    and registration_child.participation_status = 'active';

  if group_record.route_mode = 'dynamic' then
    update app_private.walking_groups set status = 'live', version = version + 1 where id = _group_id;
    dispatch_result := app_private.dispatch_next_stop(v_run_id, clock_timestamp());
    select current_stop_id into first_stop_id from app_private.group_runs where id = v_run_id;
  else
    insert into app_private.run_stops(run_id, plan_stop_id, sequence, state, opened_at)
    select v_run_id, stop.id, stop.position,
      case when stop.position = 1 then 'active'::app_private.run_stop_state else 'locked'::app_private.run_stop_state end,
      case when stop.position = 1 then clock_timestamp() else null end
    from app_private.route_plan_stops stop where stop.plan_version_id = plan_id order by stop.position;
    select id into first_stop_id from app_private.run_stops where run_id = v_run_id and sequence = 1;
    if first_stop_id is null then raise exception 'EMPTY_ROUTE' using errcode = '23514'; end if;
    update app_private.group_runs set current_stop_id = first_stop_id, version = version + 1 where id = v_run_id;
    insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
    select first_stop_id, participant.id from app_private.run_participants participant
    where participant.run_id = v_run_id and participant.attendance = 'present';
    update app_private.walking_groups set status = 'live', version = version + 1 where id = _group_id;
    dispatch_result := jsonb_build_object('decision', 'legacy', 'stopId', first_stop_id);
  end if;
  insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
  values (v_run_id, first_stop_id, 'run.started', actor, jsonb_build_object('routeMode', group_record.route_mode));
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'run.started', 'group_run', v_run_id, jsonb_build_object('routeMode', group_record.route_mode));
  result := jsonb_build_object('runId', v_run_id, 'dispatch', dispatch_result);
  insert into app_private.command_receipts(actor_id, command_type, idempotency_key, request_hash, safe_result, expires_at)
  values (actor, 'run.start', _idempotency_key, _request_hash, result, now() + interval '2 days') returning * into receipt;
  return receipt.safe_result;
end;
$function$
;

CREATE OR REPLACE FUNCTION api.run_scan(_run_id uuid, _expected_stop_id uuid, _expected_run_version integer, _credential text, _method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  credential_record app_private.portal_credentials;
  inserted_count integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  if actor is null then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.current_stop_id <> _expected_stop_id or run_record.version <> _expected_run_version then raise exception 'STALE_VERSION' using errcode = '40001'; end if;
  if run_record.status <> 'live' then raise exception 'RUN_NOT_LIVE' using errcode = '23514'; end if;
  if not app_private.is_current_leader(run_record.group_id, actor) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select credential.* into credential_record
  from app_private.run_stops run_stop
  left join app_private.route_plan_stops plan_stop on plan_stop.id = run_stop.plan_stop_id
  join app_private.portals portal on portal.id = coalesce(run_stop.portal_id, plan_stop.portal_id)
  join app_private.portal_credentials credential on credential.portal_id = portal.id
  where run_stop.id = _expected_stop_id
    -- A pause means "no new groups". A group already inside may still scan and
    -- finish safely; a direct close remains blocked.
    and portal.operation_status in ('open', 'paused')
    and credential.revoked_at is null and credential.valid_from <= now()
    and (credential.valid_until is null or credential.valid_until > now())
    and (
      (_method = 'qr' and credential.token_hash = extensions.digest(convert_to(_credential, 'utf8'), 'sha256'))
      or (_method = 'short_code' and credential.short_code_hash = extensions.digest(convert_to(upper(trim(_credential)), 'utf8'), 'sha256'))
    )
  order by credential.version desc limit 1;
  if credential_record.id is null then raise exception 'WRONG_PORTAL' using errcode = '22023'; end if;
  perform app_private.assert_finale_arrival_window(_run_id,_expected_stop_id);
  insert into app_private.scan_evidence(run_stop_id, credential_id, credential_version, actor_id, validation_method)
  values (_expected_stop_id, credential_record.id, credential_record.version, actor, _method)
  on conflict (run_stop_id) do nothing;
  get diagnostics inserted_count=row_count;
  if inserted_count>0 then
    insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
    values (_run_id, _expected_stop_id, 'stop.scanned', actor, jsonb_build_object('method', _method));
  end if;
  return jsonb_build_object('accepted', true, 'stopId', _expected_stop_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION app_private.assert_arrival_credential(_run_id uuid, _stop_id uuid, _version integer, _credential text, _method text, _portal_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r app_private.group_runs; p app_private.portals; credentialid uuid;
begin
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into r from app_private.group_runs where id=_run_id for update;
 if r.id is null or not app_private.is_current_leader(r.group_id,auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if r.version<>_version or r.current_stop_id is distinct from _stop_id then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 if r.status<>'live' then raise exception 'RUN_NOT_LIVE'; end if;
 select portal.* into p from app_private.run_stops s left join app_private.route_plan_stops plan on plan.id=s.plan_stop_id
 join app_private.portals portal on portal.id=coalesce(s.portal_id,plan.portal_id) where s.id=_stop_id and s.run_id=_run_id and s.state='active' for share of portal;
 if p.id is null or (_portal_id is not null and p.id<>_portal_id) then raise exception 'WRONG_PORTAL'; end if;
 if p.operation_status not in ('open','paused') then raise exception 'PORTAL_UNAVAILABLE'; end if;
 if _method not in ('qr','short_code') or char_length(coalesce(_credential,'')) not between 4 and 160 then raise exception 'WRONG_PORTAL'; end if;
 select c.id into credentialid from app_private.portal_credentials c where c.portal_id=p.id and c.revoked_at is null
 and c.valid_from<=now() and (c.valid_until is null or c.valid_until>now())
 and ((_method='qr' and c.token_hash=extensions.digest(convert_to(_credential,'utf8'),'sha256'))
 or (_method='short_code' and c.short_code_hash=extensions.digest(convert_to(upper(trim(_credential)),'utf8'),'sha256')))
 order by c.version desc limit 1;
 if credentialid is null then raise exception 'WRONG_PORTAL'; end if;
 perform app_private.assert_finale_arrival_window(_run_id,_stop_id);
 return credentialid;
end $function$
;

CREATE OR REPLACE FUNCTION app_private.dispatch_next_stop_before_visit_preference(_run_id uuid, _decision_at timestamp with time zone DEFAULT clock_timestamp(), _force_finale boolean DEFAULT false, _preferred_portal_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  run_record app_private.group_runs;
  group_record app_private.walking_groups;
  schedule app_private.group_schedule_revisions;
  settings app_private.event_route_settings;
  source_node_id uuid;
  final_node_id uuid;
  needs_step_free boolean;
  v_child_count integer;
  candidate record;
  finale_reservation_id uuid;
  ordinary_reservation_id uuid;
  next_stop_id uuid;
  next_sequence integer;
  potential_count integer := 0;
  finale_path record;
  earliest_finale timestamptz;
  decision_number integer;
  candidate_summary jsonb := '[]'::jsonb;
  frozen_publication_id uuid; commitment app_private.finale_publication_commitments; finale_details jsonb; waiting_until timestamptz;
begin
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.status <> 'live' or run_record.current_stop_id is not null then
    raise exception 'RUN_NOT_DISPATCHABLE' using errcode = '23514';
  end if;
  select * into group_record from app_private.walking_groups where id = run_record.group_id;
  if group_record.route_mode <> 'dynamic' then raise exception 'NOT_DYNAMIC_RUN' using errcode = '23514'; end if;
  select * into schedule from app_private.group_schedule_revisions where id = run_record.schedule_revision_id and state = 'published';
  select * into settings from app_private.event_route_settings where event_id = group_record.event_id;
  frozen_publication_id:=app_private.run_start_publication(run_record.id);
  perform app_private.ensure_finale_commitment(frozen_publication_id);
  select * into commitment from app_private.finale_publication_commitments where finale_publication_commitments.publication_id=frozen_publication_id;
  if schedule.id is null or settings.planner_mode <> 'dynamic' then raise exception 'DYNAMIC_PLANNER_NOT_READY' using errcode = '23514'; end if;
  if commitment.publication_id is null then return app_private.pause_for_finale_conflict(_run_id,'FINAL_RESERVATION_REQUIRED',_decision_at);end if;
  finale_details:=app_private.run_finale_details(_run_id,_decision_at);
  if not (finale_details->>'eligible')::boolean then return app_private.pause_for_finale_conflict(_run_id,finale_details->>'code',_decision_at);end if;
  finale_reservation_id:=app_private.try_reserve_finale(_run_id,(finale_details->>'earliestArrivalAt')::timestamptz,_decision_at);
  if finale_reservation_id is null then return app_private.pause_for_finale_conflict(_run_id,'FINAL_RESERVATION_CONFLICT',_decision_at);end if;
  if _decision_at>=(finale_details->>'waitingUntil')::timestamptz then
    if _preferred_portal_id is not null then raise exception 'PREFERRED_PORTAL_UNAVAILABLE' using errcode='23514';end if;
    _force_finale:=true;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(group_record.event_id::text || ':route-dispatch', 0));

  update app_private.portal_reservations set status = 'expired', version = version + 1
  where event_id = group_record.event_id and status = 'held' and expires_at <= _decision_at;
  select count(*) into v_child_count from app_private.run_participants where run_id = _run_id and attendance = 'present';
  select exists (
    select 1 from app_private.run_participants participant
    join app_private.registration_children registration_child on registration_child.id = participant.registration_child_id
    join app_private.children child on child.id = registration_child.child_id
    where participant.run_id = _run_id and participant.attendance = 'present'
      and nullif(trim(child.accessibility_note), '') is not null
  ) into needs_step_free;
  select coalesce(max(sequence), 0) + 1 into next_sequence from app_private.run_stops where run_id = _run_id;
  select coalesce(max(sequence), 0) + 1 into decision_number from app_private.dispatch_decisions where run_id = _run_id;

  select node.id into source_node_id
  from app_private.run_stops stop
  left join app_private.route_plan_stops old_stop on old_stop.id=stop.plan_stop_id
  join app_private.walking_nodes node on node.portal_id = coalesce(stop.portal_id,old_stop.portal_id) and node.event_id = group_record.event_id and node.verified_at is not null
  where stop.run_id = _run_id and stop.state = 'completed'
    and exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=stop.id)
  order by stop.sequence desc limit 1;
  if source_node_id is null then
    select (p.point_snapshot->>'walking_node_id')::uuid into source_node_id
    from app_private.group_start_publications p
    where p.id=frozen_publication_id
    order by p.publication_order desc limit 1;
  end if;
  select node.id into final_node_id from app_private.walking_nodes node
  where node.event_id = group_record.event_id and node.kind = 'portal'
    and node.portal_id = commitment.portal_id and node.verified_at is not null
  order by node.id limit 1;
  if source_node_id is null or final_node_id is null then raise exception 'NO_SAFE_WALKING_PATH' using errcode = '23514'; end if;

  -- A safe terminal destination is a prerequisite for every ordinary step.
  -- Never keep dispatching houses after the finale has become unavailable.
  if not settings.finale_available or not exists (
    select 1 from app_private.portals portal
    where portal.id = settings.final_portal_id and portal.operation_status in ('open', 'scheduled')
  ) then
    update app_private.group_runs set status = 'paused', version = version + 1 where id = _run_id;
    insert into app_private.route_alerts(event_id, group_id, run_id, portal_id, priority, code, message)
    select group_record.event_id, group_record.id, _run_id, settings.final_portal_id, 'urgent', 'FINALE_UNAVAILABLE',
      'De eindpoort is niet veilig beschikbaar. Activeer de voorbereide noodafsluiting.'
    where not exists (select 1 from app_private.route_alerts where run_id = _run_id and status = 'open' and code = 'FINALE_UNAVAILABLE');
    insert into app_private.dispatch_decisions(event_id, run_id, sequence, decision, input_snapshot, candidate_summary, reason)
    values (group_record.event_id, _run_id, decision_number, 'emergency', jsonb_build_object('decidedAt', _decision_at), candidate_summary,
      'Eindpoort niet beschikbaar; geen adres automatisch gepubliceerd');
    return jsonb_build_object('decision', 'emergency', 'paused', true);
  end if;

  if not _force_finale and _decision_at < schedule.effective_ordinary_stop_at then
    for candidate in
      select portal.id as portal_id, portal.world_id, portal.name,
        source_path.distance_m as incoming_distance_m, source_path.duration_seconds as incoming_seconds,
        source_path.edge_ids as incoming_edge_ids,
        final_path.duration_seconds as finale_seconds,
        _decision_at + make_interval(secs => source_path.duration_seconds::integer) as arrival_at,
        (physical.assessment->>'occupiedUntil')::timestamptz as departure_at,
        (physical.assessment->>'plannedDepartureAt')::timestamptz as service_until,
        (physical.assessment->>'occupiedUntil')::timestamptz+make_interval(secs=>final_path.duration_seconds::integer) as earliest_finale_at,
        source_path.duration_seconds
          + case when portal.world_id = (
              select previous_portal.world_id from app_private.run_stops previous_stop
              join app_private.portals previous_portal on previous_portal.id = previous_stop.portal_id
              where previous_stop.run_id = _run_id and previous_stop.state = 'completed'
              order by previous_stop.sequence desc limit 1
            ) then 120 else 0 end
          + (select count(*) * 30 from app_private.portal_reservations pressure
             where pressure.portal_id = portal.id and pressure.status in ('held', 'active')) as score
      from app_private.portals portal
      left join app_private.portal_applications application on application.id = portal.application_id
      join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
      join app_private.walking_nodes portal_node on portal_node.event_id = portal.event_id and portal_node.kind = 'portal'
        and portal_node.portal_id = portal.id and portal_node.verified_at is not null
      cross join lateral app_private.walking_path_metrics(group_record.event_id, source_node_id, portal_node.id, needs_step_free) source_path
      cross join lateral app_private.walking_path_metrics(group_record.event_id, portal_node.id, final_node_id, needs_step_free) final_path
      cross join lateral (select app_private.assess_ordinary_portal(group_record.event_id,group_record.id,portal.id,
        _decision_at+make_interval(secs=>source_path.duration_seconds::integer),v_child_count,_decision_at) assessment) physical
      where portal.event_id = group_record.event_id
        and portal.id <> settings.final_portal_id
        and (_preferred_portal_id is null or portal.id = _preferred_portal_id)
        and portal.approval_status = 'approved' and app_private.portal_has_verified_walking_connection(portal.id) and portal.lifecycle_status='active' and portal.operation_status in ('open','scheduled')
        and not exists(select 1 from app_private.group_start_publications pub where pub.id=frozen_publication_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
        and (not needs_step_free or coalesce((select info.information->>'accessibility' from app_private.portal_visit_information info where info.portal_id=portal.id),application.private_draft_data ->> 'accessibility','') = 'step_free')
        and not exists (select 1 from app_private.run_stops seen left join app_private.route_plan_stops old_seen on old_seen.id=seen.plan_stop_id where seen.run_id = _run_id and coalesce(seen.portal_id,old_seen.portal_id) = portal.id and (seen.state='active' or exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=seen.id)))
        and (physical.assessment->>'eligible')::boolean
        and (physical.assessment->>'occupiedUntil')::timestamptz <= schedule.effective_ordinary_stop_at
        and (physical.assessment->>'occupiedUntil')::timestamptz+make_interval(secs=>final_path.duration_seconds::integer) <= commitment.reserved_arrival_at+make_interval(secs=>commitment.grace_seconds)
      order by score, portal.id
    loop
      candidate_summary := candidate_summary || jsonb_build_array(jsonb_build_object(
        'portalId', candidate.portal_id, 'walkSeconds', candidate.incoming_seconds,
        'finaleSeconds', candidate.finale_seconds, 'score', candidate.score
      ));
      finale_reservation_id := app_private.try_reserve_finale(_run_id, candidate.earliest_finale_at, _decision_at);
      if finale_reservation_id is null then continue; end if;
      insert into app_private.portal_reservations(
        event_id, portal_id, group_id, run_id, kind, status,
        reserved_from, reserved_until, child_count, expires_at, service_until
      ) values (
        group_record.event_id, candidate.portal_id, group_record.id, _run_id, 'ordinary', 'active',
        candidate.arrival_at, candidate.departure_at, v_child_count,
        candidate.departure_at + make_interval(secs => settings.reservation_ttl_seconds), candidate.service_until
      ) returning id into ordinary_reservation_id;
      insert into app_private.run_stops(
        run_id, portal_id, reservation_id, stop_kind, sequence, state, opened_at
      ) values (
        _run_id, candidate.portal_id, ordinary_reservation_id, 'ordinary', next_sequence, 'active', _decision_at
      ) returning id into next_stop_id;
      insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
      select next_stop_id, participant.id from app_private.run_participants participant
      where participant.run_id = _run_id and participant.attendance = 'present';
      update app_private.group_runs set current_stop_id = next_stop_id, version = version + 1 where id = _run_id;
      insert into app_private.dispatch_decisions(
        event_id, run_id, sequence, selected_portal_id, selected_kind, decision,
        input_snapshot, candidate_summary, reason
      ) values (
        group_record.event_id, _run_id, decision_number, candidate.portal_id, 'ordinary', 'ordinary',
        jsonb_build_object(
          'decidedAt', _decision_at, 'sourceNodeId', source_node_id, 'childCount', v_child_count,
          'effectiveStopAt', schedule.effective_ordinary_stop_at, 'finalPortalId', settings.final_portal_id,
          'requiresStepFree', needs_step_free, 'incomingEdgeIds', candidate.incoming_edge_ids
        ), candidate_summary, 'Beste geldige kandidaat op veilige looptijd, beschikbaarheid en finalehaalbaarheid'
      );
      insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
      values (_run_id, next_stop_id, 'stop.dispatched', jsonb_build_object('kind', 'ordinary', 'portalId', candidate.portal_id));
      return jsonb_build_object('decision', 'ordinary', 'stopId', next_stop_id, 'portalId', candidate.portal_id);
    end loop;

    if _preferred_portal_id is not null then
      raise exception 'PREFERRED_PORTAL_UNAVAILABLE' using errcode = '23514';
    end if;

    select count(*) into potential_count
    from app_private.portals portal
    join app_private.portal_private_locations location on location.portal_id = portal.id and location.verified_at is not null
    join app_private.walking_nodes portal_node on portal_node.portal_id = portal.id and portal_node.event_id = group_record.event_id and portal_node.verified_at is not null
    cross join lateral app_private.walking_path_metrics(group_record.event_id, source_node_id, portal_node.id, needs_step_free) source_path
    cross join lateral app_private.walking_path_metrics(group_record.event_id, portal_node.id, final_node_id, needs_step_free) final_path
    where portal.event_id = group_record.event_id and portal.id <> settings.final_portal_id
      and portal.approval_status = 'approved' and app_private.portal_has_verified_walking_connection(portal.id) and portal.lifecycle_status='active' and portal.operation_status in ('open','scheduled')
        and not exists(select 1 from app_private.group_start_publications pub where pub.id=frozen_publication_id
          and coalesce((pub.point_snapshot->>'counts_as_first_portal_visit')::boolean,false)=false
          and pub.point_snapshot->>'linked_portal_id'=portal.id::text)
      and not exists (select 1 from app_private.run_stops seen left join app_private.route_plan_stops old_seen on old_seen.id=seen.plan_stop_id where seen.run_id = _run_id and coalesce(seen.portal_id,old_seen.portal_id) = portal.id and (seen.state='active' or exists(select 1 from app_private.scan_evidence evidence where evidence.run_stop_id=seen.id)))
      and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds)::integer) <= schedule.effective_ordinary_stop_at
      and _decision_at + make_interval(secs => (source_path.duration_seconds + settings.ordinary_visit_seconds + settings.route_buffer_seconds + final_path.duration_seconds)::integer) <= commitment.reserved_arrival_at+make_interval(secs=>commitment.grace_seconds);
    if potential_count > 0 then
      insert into app_private.dispatch_decisions(event_id, run_id, sequence, decision, input_snapshot, candidate_summary, reason)
      values (group_record.event_id, _run_id, decision_number, 'wait',
        jsonb_build_object('decidedAt', _decision_at, 'effectiveStopAt', schedule.effective_ordinary_stop_at),
        candidate_summary, 'Veilige kandidaten zijn tijdelijk bezet; opnieuw beoordelen');
      insert into app_private.route_alerts(event_id, group_id, run_id, priority, code, message)
      select group_record.event_id, group_record.id, _run_id, 'warning', 'NO_CURRENT_CAPACITY',
        'Geen gewone poort is nu reserveerbaar; automatische herbeoordeling is nodig.'
      where not exists (select 1 from app_private.route_alerts where run_id = _run_id and status = 'open' and code = 'NO_CURRENT_CAPACITY');
      return jsonb_build_object('decision', 'wait', 'retryAfterSeconds', 120);
    end if;
  end if;

  select * into finale_path from app_private.walking_path_metrics(group_record.event_id, source_node_id, final_node_id, needs_step_free);
  if finale_path.duration_seconds is null then raise exception 'NO_SAFE_FINALE_PATH' using errcode = '23514'; end if;
  earliest_finale := _decision_at + make_interval(secs => finale_path.duration_seconds::integer);
  finale_reservation_id := app_private.try_reserve_finale(_run_id, earliest_finale, _decision_at);
  if finale_reservation_id is null then return app_private.pause_for_finale_conflict(_run_id,'FINAL_RESERVATION_CONFLICT',_decision_at);end if;
  waiting_until:=commitment.reserved_arrival_at-make_interval(secs=>finale_path.duration_seconds::integer);
  if _decision_at<waiting_until then
    if not exists(select 1 from app_private.dispatch_decisions d where d.run_id=_run_id and d.decision='wait'
      and d.input_snapshot->>'waitingReason'='finale_window'
      and d.input_snapshot->>'reservationId'=finale_reservation_id::text
      and (d.input_snapshot->>'waitingUntil')::timestamptz=waiting_until) then
      insert into app_private.dispatch_decisions(event_id,run_id,sequence,decision,input_snapshot,candidate_summary,reason)
      values(group_record.event_id,_run_id,decision_number,'wait',jsonb_build_object('decidedAt',_decision_at,
        'waitingReason','finale_window','waitingUntil',waiting_until,'reservationId',finale_reservation_id,
        'reservedArrivalAt',commitment.reserved_arrival_at,'safeWaitingInstruction',commitment.safe_waiting_instruction),candidate_summary,'Wachten tot vertrek voor de vaste gepubliceerde finale-afspraak');
    end if;
    return jsonb_build_object('decision','wait','waitingReason','finale_window','waitingUntil',waiting_until,
      'reservedArrivalAt',commitment.reserved_arrival_at,'safeWaitingInstruction',commitment.safe_waiting_instruction,'reservationId',finale_reservation_id);
  end if;
  update app_private.portal_reservations set status = 'active', version = version + 1 where id = finale_reservation_id;
  insert into app_private.run_stops(run_id, portal_id, reservation_id, stop_kind, sequence, state, opened_at)
  values (_run_id, settings.final_portal_id, finale_reservation_id, 'finale', next_sequence, 'active', _decision_at)
  returning id into next_stop_id;
  insert into app_private.stop_participant_statuses(run_stop_id, run_participant_id)
  select next_stop_id, participant.id from app_private.run_participants participant
  where participant.run_id = _run_id and participant.attendance = 'present';
  update app_private.group_runs set current_stop_id = next_stop_id, version = version + 1 where id = _run_id;
  insert into app_private.dispatch_decisions(
    event_id, run_id, sequence, selected_portal_id, selected_kind, decision,
    input_snapshot, candidate_summary, reason
  ) values (
    group_record.event_id, _run_id, decision_number, settings.final_portal_id, 'finale', 'finale',
    jsonb_build_object('decidedAt', _decision_at, 'sourceNodeId', source_node_id, 'walkSeconds', finale_path.duration_seconds),
    candidate_summary, 'Stopgrens of kandidaatfilter bereikt; verplichte eindpoort gereserveerd'
  );
  insert into app_private.journey_events(run_id, stop_id, event_type, safe_metadata)
  values (_run_id, next_stop_id, 'stop.dispatched', jsonb_build_object('kind', 'finale', 'portalId', settings.final_portal_id));
  return jsonb_build_object('decision', 'finale', 'stopId', next_stop_id, 'portalId', settings.final_portal_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION api.admin_redirect_group(_run_id uuid, _target text, _preferred_portal_id uuid, _expected_run_version integer, _reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor uuid := auth.uid();
  run_record app_private.group_runs;
  group_record app_private.walking_groups;
  stop_record app_private.run_stops;
  dispatch_result jsonb;
  finale_details jsonb;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _expected_run_version is null then raise exception 'STALE_VERSION' using errcode='40001'; end if;
  perform app_private.lock_evening_event((select evening_group.event_id from app_private.group_runs evening_run join app_private.walking_groups evening_group on evening_group.id=evening_run.group_id where evening_run.id=_run_id));

  select * into run_record from app_private.group_runs where id = _run_id for update;
  if run_record.id is null or run_record.version <> _expected_run_version then
    raise exception 'STALE_VERSION' using errcode = '40001';
  end if;
  select * into group_record from app_private.walking_groups where id = run_record.group_id;
  if group_record.route_mode <> 'dynamic' or run_record.status <> 'live' then
    raise exception 'RUN_NOT_DISPATCHABLE' using errcode = '23514';
  end if;
  if not (
    app_private.has_capability(group_record.event_id, 'live_support', actor)
    or app_private.has_capability(group_record.event_id, 'groups_manage', actor)
  ) then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if _target not in ('ordinary', 'finale')
     or (_target = 'ordinary' and _preferred_portal_id is null)
     or (_target = 'finale' and _preferred_portal_id is not null) then
    raise exception 'INVALID_REDIRECT_TARGET' using errcode = '22023';
  end if;
  if char_length(trim(coalesce(_reason, ''))) not between 10 and 500 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;

  if _target='finale' then
    finale_details:=app_private.run_finale_details(_run_id,clock_timestamp());
    if not (finale_details->>'eligible')::boolean then raise exception '%',finale_details->>'code' using errcode='23514';end if;
  end if;

  if run_record.current_stop_id is not null then
    select * into stop_record from app_private.run_stops where id = run_record.current_stop_id for update;
    if stop_record.stop_kind = 'finale' then
      raise exception 'FINAL_DESTINATION_ALREADY_PUBLISHED' using errcode = '23514';
    end if;
    if exists (select 1 from app_private.scan_evidence where run_stop_id = stop_record.id) then
      raise exception 'VISIT_IN_PROGRESS' using errcode = '23514';
    end if;
    update app_private.run_stops
    set state = 'completed', outcome = 'system_skipped', completed_at = clock_timestamp(),
      completion_actor = actor, completion_reason = left(trim(_reason), 500), version = version + 1
    where id = stop_record.id;
    update app_private.stop_participant_statuses
    set status = 'skipped', required_for_completion = false,
      exclusion_reason = 'Bestemming door organisatie gewijzigd',
      reason = 'Bestemming door organisatie gewijzigd', changed_by = actor,
      decided_at = clock_timestamp(), version = version + 1
    where run_stop_id = stop_record.id and status = 'pending';
    update app_private.portal_reservations
    set status = 'cancelled', cancelled_reason = 'Bestemming door organisatie gewijzigd', version = version + 1
    where id = stop_record.reservation_id and status in ('held', 'active');
    insert into app_private.journey_events(run_id, stop_id, event_type, actor_id, safe_metadata)
    values (_run_id, stop_record.id, 'stop.admin_redirected', actor,
      jsonb_build_object('target', _target, 'reason', left(trim(_reason), 500)));
    update app_private.group_runs set current_stop_id = null, version = version + 1 where id = _run_id;
  end if;

  dispatch_result := app_private.dispatch_next_stop(
    _run_id,
    clock_timestamp(),
    _target = 'finale',
    case when _target = 'ordinary' then _preferred_portal_id else null end
  );
  insert into app_private.audit_events(event_id, actor_id, action, resource_type, resource_id, minimal_change)
  values (group_record.event_id, actor, 'group.destination_redirected', 'group_run', _run_id,
    jsonb_build_object('target', _target, 'preferredPortalId', _preferred_portal_id, 'reason', left(trim(_reason), 500)));
  return dispatch_result;
end;
$function$
;

CREATE OR REPLACE FUNCTION api.group_snapshot(_group_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare base jsonb; pid uuid; r app_private.group_runs; c app_private.finale_publication_commitments; p uuid; d app_private.dispatch_decisions; b app_private.portal_reservations;
begin
 base:=app_private.group_snapshot_before_visit_information(_group_id);
 select * into r from app_private.group_runs where id=(base#>>'{run,id}')::uuid;
 p:=case when r.id is not null then app_private.run_start_publication(r.id) else
   (select pub.id from app_private.group_start_publications pub where pub.group_id=_group_id order by publication_order desc limit 1) end;
 select * into c from app_private.finale_publication_commitments where publication_id=p;
 if c.publication_id is not null then
   base:=jsonb_set(base,'{group,expectedFinaleArrivalAt}',to_jsonb(c.reserved_arrival_at),true);
 end if;
 if r.id is not null and (not coalesce((base#>>'{run,ownEveningFinished}')::boolean,false)
   or coalesce((base#>>'{access,leader}')::boolean,false) or coalesce((base#>>'{access,support}')::boolean,false)) then
   select * into d from app_private.dispatch_decisions where run_id=r.id order by sequence desc limit 1;
   if c.publication_id is not null then
     select * into b from app_private.portal_reservations where start_publication_id=c.publication_id;
     base:=jsonb_set(base,'{run}',base->'run'||jsonb_build_object('reservedArrivalAt',c.reserved_arrival_at,
       'finaleReservation',jsonb_build_object('id',b.id,'publicationId',c.publication_id,'revision',(select pub.revision from app_private.group_start_publications pub where pub.id=c.publication_id),'reservedArrivalAt',c.reserved_arrival_at)),true);
   end if;
   if r.status='live' and r.current_stop_id is null and d.input_snapshot->>'waitingReason'='finale_window'
     and d.input_snapshot->>'reservationId'=b.id::text then
      base:=jsonb_set(base,'{run}',base->'run'||jsonb_build_object('waitingReason','finale_window',
        'waitingUntil',d.input_snapshot->'waitingUntil','safeWaitingInstruction',c.safe_waiting_instruction),true);
   elsif r.status='paused' and d.input_snapshot ? 'planningConflict' then
      base:=jsonb_set(base,'{run}',base->'run'||jsonb_build_object('planningConflict',d.input_snapshot->'planningConflict','safeWaitingInstruction',d.reason,'emergencyInstruction',d.reason),true);
   end if;
 end if;
 if r.current_stop_id is not null then
   select * into b from app_private.portal_reservations where id=(select s.reservation_id from app_private.run_stops s where s.id=r.current_stop_id)
     or bound_stop_id=r.current_stop_id order by created_at desc limit 1;
   if b.id is not null and base#>'{run,currentStop}' is not null and base#>'{run,currentStop}'<>'null'::jsonb then
     base:=jsonb_set(base,'{run,currentStop}',base#>'{run,currentStop}'||jsonb_build_object('reservedArrivalAt',b.reserved_from,
       'arrivalWindow',jsonb_build_object('from',b.reserved_from,'until',case when b.kind='finale' then b.reserved_from+make_interval(secs=>coalesce(c.grace_seconds,(select cfg.finale_turnover_seconds from app_private.event_route_settings cfg join app_private.walking_groups g on g.event_id=cfg.event_id where g.id=r.group_id),120)) else coalesce(b.service_until,b.reserved_until) end)),true);
   end if;
 end if;
 pid:=(base#>>'{run,currentStop,portal,id}')::uuid;
 if pid is null then return base; end if;
 return jsonb_set(base,'{run,currentStop,portal}',base#>'{run,currentStop,portal}'||app_private.portal_visit_information_projection(pid));
end $function$
;

CREATE OR REPLACE FUNCTION app_private.published_start_projection(_group_id uuid, _at timestamp with time zone DEFAULT clock_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p app_private.group_start_publications; result jsonb;
begin
  select * into p from app_private.group_start_publications where id=(
    select app_private.run_start_publication(r.id) from app_private.group_runs r where r.group_id=_group_id and r.status in ('live','paused') order by r.created_at desc,r.id desc limit 1);
  if p.id is null then
    select * into p from app_private.group_start_publications where group_id=_group_id order by publication_order desc limit 1;
  end if;
  if p.id is null then return null; end if;
  result:=jsonb_build_object('startsAt',p.starts_at,'revision',p.revision,
    'publishedAt',p.published_at,'addressReleaseAt',p.starts_at-interval '1 hour',
    'addressReleased',_at>=p.starts_at-interval '1 hour','canStart',_at>=p.starts_at,'timePublished',true,
    'name','Startlocatie volgt','locationName','Startlocatie volgt','startPoint','Startlocatie volgt',
    'address',null,'startAddress',null,'coordinate',null,'linkedPortalId',null);
  if _at>=p.starts_at-interval '1 hour' then
    result:=result||jsonb_build_object('name',p.point_snapshot->>'name',
      'locationName',p.point_snapshot->>'name','startPoint',p.point_snapshot->>'name',
      'address',p.point_snapshot->>'private_address','startAddress',p.point_snapshot->>'private_address',
      'linkedPortalId',p.point_snapshot->>'linked_portal_id',
      'safeApproach',p.point_snapshot->>'safe_approach','arrivalInstructions',p.point_snapshot->>'public_arrival_instructions',
      'coordinate',jsonb_build_array(
        coalesce(p.point_snapshot->>'marker_longitude',p.point_snapshot->>'geocoded_longitude',p.point_snapshot->>'longitude')::numeric,
        coalesce(p.point_snapshot->>'marker_latitude',p.point_snapshot->>'geocoded_latitude',p.point_snapshot->>'latitude')::numeric));
  end if;
  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION api.redesign_rehearsal(_event_slug text, _scenario text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ownerid uuid:=auth.uid(); realevent uuid; eventid uuid:=gen_random_uuid(); homeid uuid:=gen_random_uuid(); registrationid uuid:=gen_random_uuid();
 groupid uuid:=gen_random_uuid(); planid uuid:=gen_random_uuid(); worldid uuid:=gen_random_uuid(); childids uuid[]:='{}'; rcids uuid[]:='{}'; portalids uuid[]:='{}'; tokens text[]:='{}';
 slotid uuid:=gen_random_uuid(); nodeid uuid; previousnode uuid:=gen_random_uuid(); runid uuid; activeid uuid; r app_private.group_runs; fixtureid uuid; portalid uuid; applicationid uuid; childid uuid; rcid uuid; participantid uuid;
 i integer; n integer; operation jsonb; scenarios jsonb:='{"start": [{"op": "empty", "title": "Start zonder aanwezigen weigeren", "history": 0, "sequence": 0, "status": "before", "seals": [0, 0, 0], "error": "EMPTY_GROUP"}, {"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Twee aanwezige kinderen bereiken de poort", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 0]}, {"op": "snapshot", "title": "Afwezig kind krijgt geen zegel", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 0]}], "arrival": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "snapshot", "title": "Precies de volgende bestemming staat klaar", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "inclusive": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "snapshot", "title": "Buiten blijven krijgt dezelfde aankomstzegel", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "wrong": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "wrong", "title": "Een verkeerde poortcode weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "WRONG_PORTAL"}], "duplicate": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "repeat", "title": "Dezelfde opdracht blijft eenmalig", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "closed": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "close", "title": "Eigen oefenpoort sluiten", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij gesloten poort weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "PORTAL_UNAVAILABLE"}, {"op": "systemskip", "title": "Expliciete systeemoverslag zonder zegel", "history": 1, "sequence": 2, "status": "live", "seals": [0, 0, 0]}], "manual": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "skipall", "title": "Alle kinderen slaan de beleving over", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "complete", "title": "Zonder aankomst niet afronden", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "SCAN_REQUIRED"}, {"op": "scan", "title": "Alleen code bevestigen zonder definitieve zegels", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "complete", "title": "Met aankomst iedereen een zegel geven", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "offline": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "offline", "title": "Verbinding weg: geen serveropdracht ontvangen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Na herstel dezelfde aankomst bevestigen", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "repeat", "title": "Herhaalde ontvangst maakt geen duplicaat", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "stale": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "stale", "title": "Oude routeversie weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "STALE_VERSION"}], "early": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Aankomst bij poort 2", "history": 2, "sequence": 3, "status": "live", "seals": [2, 2, 2]}, {"op": "departall", "title": "Eigen gezin sluit af zonder finale", "history": 2, "sequence": 0, "status": "stopped", "seals": [2, 2, 2]}], "part-departure": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "departone", "title": "Een kind vertrekt; de groep loopt door", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Vertrokken kind krijgt geen volgende zegel", "history": 2, "sequence": 3, "status": "live", "seals": [2, 1, 2]}], "finale": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Aankomst bij poort 2", "history": 2, "sequence": 3, "status": "live", "seals": [2, 2, 2]}, {"op": "arrive", "title": "Aankomst bij poort 3", "history": 3, "sequence": 4, "status": "live", "seals": [3, 3, 3]}, {"op": "arrive", "title": "Aankomst bij poort 4", "history": 4, "sequence": 5, "status": "live", "seals": [4, 4, 4]}, {"op": "arrive", "title": "Finaleaankomst telt ook bij buiten blijven", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}, {"op": "snapshot", "title": "Ieder aanwezig kind heeft precies een finalezegel", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}, {"op": "repeat", "title": "Geen dubbele finale of zesde zegel", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}]}'::jsonb; spec jsonb; report jsonb:='[]'; results jsonb; request jsonb; previous jsonb;
 problem text; currentportal uuid; token text; runversion integer; stopid uuid; leavingids uuid[]; choices jsonb; started timestamptz:=clock_timestamp(); tick timestamptz;
 actualhistory integer; actualseq integer; actualstatus text; sealcounts jsonb; view jsonb; ok boolean;
begin
 select id into realevent from app_private.events where slug=_event_slug;
 if ownerid is null or realevent is null or not (app_private.has_capability(realevent,'live_support',ownerid) or app_private.has_capability(realevent,'event_admin',ownerid)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 spec:=scenarios->_scenario;
 if spec is null then raise exception 'INVALID_SCENARIO'; end if;
 perform pg_advisory_xact_lock(hashtextextended(ownerid::text||':redesign-rehearsal',0));
 begin
  insert into app_private.events(id,slug,title,local_date,phase,price_cents,settings) values(eventid,'rehearsal-'||replace(eventid::text,'-',''),'Geïsoleerde generale',(now() at time zone 'Europe/Amsterdam')::date,'live',0,'{"rehearsal":true}');
  insert into app_private.households(id,label,primary_contact_user_id) values(homeid,'Oefengezin',ownerid);
  insert into app_private.household_members(household_id,user_id,relation_role) values(homeid,ownerid,'owner');
  insert into app_private.registrations(id,event_id,household_id,status,reference) values(registrationid,eventid,homeid,'submitted','LAB-'||registrationid::text);
  for i in 1..3 loop
   insert into app_private.children(household_id,first_name,age_at_event) values(homeid,(array['Oefenkind A','Oefenkind B','Oefenkind C'])[i],8) returning id into childid;
   insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents) values(eventid,registrationid,childid,0) returning id into rcid;
   childids:=array_append(childids,childid);rcids:=array_append(rcids,rcid);
  end loop;
  insert into app_private.start_slots(id,event_id,external_id,name,location_name,private_address,starts_at,max_groups,max_children) values(slotid,eventid,'lab-start','Oefenstart','Oefenlocatie','Geïsoleerd oefenadres',now()-interval '1 hour',1,20);
  insert into app_private.walking_nodes(id,event_id,external_id,kind,coordinate,verified_at) values(previousnode,eventid,'lab-start','start',point(4.26,52.10),now());
  for i in 1..5 loop
   worldid:=gen_random_uuid();
   insert into app_private.worlds(id,event_id,slug,name,sort_order) values(worldid,eventid,'oefenwereld-'||i,'Oefenwereld '||i,i);
   applicationid:=gen_random_uuid();portalid:=gen_random_uuid();token:=encode(extensions.gen_random_bytes(32),'hex');
   insert into app_private.portal_applications(id,event_id,applicant_user_id,review_status) values(applicationid,eventid,ownerid,'approved');
   insert into app_private.portals(id,event_id,application_id,world_id,name,intensity,operation_status) values(portalid,eventid,applicationid,worldid,'Oefenpoort '||i,1,'open');
   insert into app_private.portal_owners(portal_id,user_id,role) values(portalid,ownerid,'owner');
   insert into app_private.portal_credentials(portal_id,token_hash,short_code_hash,version,valid_from) values(portalid,extensions.digest(token,'sha256'),extensions.digest(upper(token),'sha256'),1,now()-interval '1 minute');
   insert into app_private.portal_private_locations(portal_id,street,house_number,postal_code,latitude,longitude,verified_at) values(portalid,'Oefenstraat',i::text,'0000XX',52.10,4.26+i*.0001,now());
   insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,max_concurrent_groups,max_children_per_visit) values(portalid,now()-interval '1 hour',now()+interval '5 hours',3,1,20);
   nodeid:=gen_random_uuid();
   insert into app_private.walking_nodes(id,event_id,kind,portal_id,coordinate,verified_at) values(nodeid,eventid,'portal',portalid,point(4.26+i*.0001,52.10),now());
   insert into app_private.walking_edges(event_id,from_node_id,to_node_id,distance_m,duration_seconds,approved_at,approved_by) values(eventid,previousnode,nodeid,10,10,now(),ownerid);
   previousnode:=nodeid;
   portalids:=array_append(portalids,portalid);tokens:=array_append(tokens,token);
  end loop;
  insert into app_private.walking_groups(id,event_id,code,status,start_slot_id) values(groupid,eventid,'LAB-01','ready',slotid);
  insert into app_private.group_leaders(group_id,user_id,active_from,revision) values(groupid,ownerid,now()-interval '1 minute',1);
  insert into app_private.group_registrations(group_id,registration_id,assignment_revision,published_at) values(groupid,registrationid,1,now());
  insert into app_private.route_plan_versions(id,group_id,revision,state,input_hash) values(planid,groupid,1,'draft',eventid::text);
  for i in 1..5 loop
   insert into app_private.route_plan_stops(plan_version_id,position,portal_id,planned_arrival_at,planned_departure_at) values(planid,i,portalids[i],now()+i*interval '5 minutes',now()+(i*5+3)*interval '1 minute');
  end loop;
  update app_private.route_plan_versions set state='published',published_at=now() where id=planid;
  update app_private.walking_groups set current_plan_version_id=planid where id=groupid;
  for operation in select * from jsonb_array_elements(spec) loop
   problem:=null;tick:=clock_timestamp();
   select * into r from app_private.group_runs where id=runid;
   if r.id is not null then
    select s.sequence,coalesce(s.portal_id,p.portal_id) into n,currentportal from app_private.run_stops s left join app_private.route_plan_stops p on p.id=s.plan_stop_id where s.id=r.current_stop_id;
    token:=tokens[array_position(portalids,currentportal)];
    select jsonb_object_agg(rp.id::text,case when rc.child_id=childids[2] then 'skipped' else 'visited' end) into choices
     from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id where rp.run_id=runid and rp.attendance='present';
    request:=jsonb_build_object('run',runid,'stop',r.current_stop_id,'version',r.version,'token',token,'choices',choices,'key',gen_random_uuid()::text);
   end if;
   begin
    case operation->>'op'
    when 'empty' then perform api.run_start(groupid,'{}'::uuid[],(select version from app_private.walking_groups where id=groupid),gen_random_uuid()::text,'empty');
    when 'start' then
      results:=api.run_start(groupid,case when _scenario='start' then rcids[1:2] else rcids end,(select version from app_private.walking_groups where id=groupid),gen_random_uuid()::text,'start');
      runid:=(results->>'runId')::uuid;
      -- A genuine finale flag on the final isolated stop exercises the same completion transaction.
      insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count) values(eventid,portalids[5],groupid,runid,'finale','active',clock_timestamp()-interval '1 second',clock_timestamp()+interval '2 hours',3) returning id into fixtureid;
      update app_private.run_stops set stop_kind='finale',portal_id=portalids[5],reservation_id=fixtureid,plan_stop_id=null where run_id=runid and sequence=5;
    when 'arrive','wrong','stale','repeat' then
      if operation->>'op'='repeat' then request:=previous; end if;
      perform api.run_arrive_and_advance((request->>'run')::uuid,(request->>'stop')::uuid,(request->>'version')::integer-case when operation->>'op'='stale' then 1 else 0 end,
       case when operation->>'op'='wrong' then encode(extensions.gen_random_bytes(32),'hex') else request->>'token' end,request->'choices',request->>'key');
      previous:=request;
    when 'close' then perform api.portal_set_operational_state(currentportal,'closed',(select version from app_private.portals where id=currentportal),'Geïsoleerde generale');
    when 'systemskip' then perform api.run_system_skip(runid,r.current_stop_id,r.version,'Gesloten oefenpoort',gen_random_uuid()::text,'system-skip');
    when 'skipall' then perform api.run_bulk_skip_pending(runid,r.current_stop_id,r.version,'Met oefenouder bevestigd',gen_random_uuid()::text,'skip-all');
    when 'complete' then perform api.run_complete_stop(runid,r.current_stop_id,r.version,true,gen_random_uuid()::text,'manual-complete');
    when 'scan' then perform api.run_scan(runid,r.current_stop_id,r.version,token,'qr');
    when 'departone','departall' then
      select array_agg(rp.id order by rp.id) into leavingids from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id where rp.run_id=runid and rp.attendance='present' and (operation->>'op'='departall' or rc.child_id=childids[2]);
      perform api.run_end_early(runid,r.version,leavingids,'Eigen oefengezin sluit af',gen_random_uuid()::text);
      -- Restore the immutable child order used by the measurement projection.
      select array_agg(rc.child_id order by array_position(rcids,rc.id)) into childids from app_private.registration_children rc where rc.id=any(rcids);
    when 'offline' then null; -- Simulated transport omission: deliberately issue no SQL command.
    when 'snapshot' then null;
    else raise exception 'INVALID_SCENARIO';
    end case;
   exception when others then problem:=SQLERRM;
   end;
   select * into r from app_private.group_runs where id=runid;
   select count(*) into actualhistory from app_private.run_stops where run_id=runid and state='completed';
   select coalesce(sequence,0) into actualseq from app_private.run_stops where id=r.current_stop_id;actualseq:=coalesce(actualseq,0);
   actualstatus:=coalesce(r.status::text,'before');
   select jsonb_agg((select count(*) from app_private.poortenboek_passport_seals seal where seal.event_id=eventid and seal.child_id=rc.child_id) order by array_position(rcids,rc.id)) into sealcounts from app_private.registration_children rc where rc.id=any(rcids);
   ok:=problem is not distinct from operation->>'error' and actualhistory=(operation->>'history')::integer and actualseq=(operation->>'sequence')::integer and actualstatus=operation->>'status' and sealcounts=operation->'seals';
   if _scenario='finale' and actualstatus='completed' then ok:=ok and (select count(*)=3 from app_private.poortenboek_passport_seals where event_id=eventid and finale); end if;
   view:=jsonb_build_object('connected',operation->>'op'<>'offline','parent',jsonb_build_object('status',actualstatus,'stop',case when actualseq=0 then 'Geen actieve bestemming' else 'Oefenpoort '||actualseq end,'sequence',actualseq,'version',coalesce(r.version,0),'arrived',actualhistory>0,'endedEarly',r.stopped_reason='all_participants_departed'),
    'gate',jsonb_build_object('name','Geïsoleerde oefenpoort','code','LAB','status',coalesce((select operation_status from app_private.portals where id=currentportal),'open'),'scanned',exists(select 1 from app_private.scan_evidence where run_stop_id=r.current_stop_id)),
    'children',(select jsonb_agg(jsonb_build_object('id',rc.id,'name',c.first_name,'attendance',coalesce(rp.attendance::text,'absent'),'choice','Eigen keuze','seals',(select count(*) from app_private.poortenboek_passport_seals where event_id=eventid and child_id=c.id),'finaleSeals',(select count(*) from app_private.poortenboek_passport_seals where event_id=eventid and child_id=c.id and finale)) order by array_position(rcids,rc.id)) from app_private.registration_children rc join app_private.children c on c.id=rc.child_id left join app_private.run_participants rp on rp.registration_child_id=rc.id and rp.run_id=runid where rc.id=any(rcids)),
    'history',coalesce((select jsonb_agg(jsonb_build_object('sequence',sequence,'name','Oefenpoort '||sequence,'outcome',outcome,'arrived',outcome<>'system_skipped') order by sequence) from app_private.run_stops where run_id=runid and state='completed'),'[]'::jsonb));
   report:=report||jsonb_build_array(jsonb_build_object('title',operation->>'title','expectation',(operation-'op'-'title')::text,'actual',jsonb_build_object('error',problem,'history',actualhistory,'sequence',actualseq,'status',actualstatus,'seals',sealcounts)::text,'passed',coalesce(ok,false),'at',clock_timestamp(),'durationMs',round(extract(epoch from clock_timestamp()-tick)*1000),'command',operation->>'op','view',view));
  end loop;
  raise exception using errcode='P7711',message='ROLLBACK_ISOLATED_REHEARSAL';
 exception when sqlstate 'P7711' then null;
 end;
 return jsonb_build_object('scenarioId',_scenario,'title',_scenario,'startedAt',started,'endedAt',clock_timestamp(),'passed',not exists(select 1 from jsonb_array_elements(report) item where not (item->>'passed')::boolean),'steps',report,'environment','Isolated SQL transaction; fixtures rolled back; external transport is not measured');
end $function$
;

create or replace function api.portal_arrivals_snapshot(_portal_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $function$
declare actor uuid:=auth.uid(); p app_private.portals;
begin
 select * into p from app_private.portals where id=_portal_id;
 if actor is null or p.id is null or not (
  exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.user_id=actor and o.revoked_at is null)
  or app_private.has_capability(p.event_id,'portals_manage',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return (
 with latest_runs as materialized (
  select distinct on(r.group_id) r.* from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id
  where g.event_id=p.event_id order by r.group_id,r.created_at desc,r.id desc
 ), latest_publications as materialized (
  select distinct on(pub.group_id) pub.* from app_private.group_start_publications pub
  where pub.event_id=p.event_id order by pub.group_id,pub.publication_order desc
 ), raw_arrivals as (
  select g.id group_id,g.system_code group_code,g.display_name,s.planned_arrival_at,s.planned_departure_at,
    coalesce(rs.state::text,'planned') state,'assigned'::text classification,
    null::uuid reservation_id,null::uuid publication_id,null::integer publication_revision,
    case when r.status in ('live','paused') then (select count(*)::integer from app_private.run_participants rp where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null) else null end children,
    2 priority
  from app_private.route_plan_stops s join app_private.route_plan_versions plan on plan.id=s.plan_version_id and plan.state='published'
  join app_private.walking_groups g on g.id=plan.group_id
  left join latest_runs r on r.group_id=g.id
  left join app_private.run_stops rs on rs.run_id=r.id and rs.plan_stop_id=s.id
  where s.portal_id=p.id and (
    (r.status in ('live','paused') and r.active_plan_version_id=plan.id)
    or (g.route_mode='legacy' and (r.id is null or (r.status in ('completed','stopped') and plan.created_at>r.created_at))))
  union all
  select g.id,g.system_code,g.display_name,b.reserved_from,coalesce(b.service_until,b.reserved_until),
    case b.status when 'active' then 'active' when 'completed' then 'completed' else 'planned' end,'assigned',
    b.id,b.start_publication_id,pub.revision,b.child_count,case when b.status='completed' then 3 else 0 end
  from app_private.portal_reservations b join app_private.walking_groups g on g.id=b.group_id
  left join latest_runs r on r.group_id=b.group_id
  left join latest_publications current_pub on current_pub.group_id=b.group_id
  left join app_private.group_start_publications pub on pub.id=b.start_publication_id
  where b.portal_id=p.id and b.status in ('held','active','completed')
    and (b.status='completed' or
      ((b.expires_at is null or b.expires_at>clock_timestamp()) and
       ((b.run_id is not null and r.id=b.run_id and r.status in ('ready','live','paused'))
        or (b.run_id is null and (b.start_publication_id is null or b.start_publication_id=current_pub.id)
          and (coalesce(r.status::text,'') not in ('completed','stopped') or current_pub.id is distinct from app_private.run_start_publication(r.id))))))
  union all
  select g.id,g.system_code,g.display_name,s.expected_finale_arrival_at,
   s.expected_finale_arrival_at+make_interval(secs=>cfg.finale_show_seconds+cfg.finale_turnover_seconds),'planned','forecast',null,null,null,null,4
  from app_private.group_schedule_revisions s join app_private.walking_groups g on g.id=s.group_id
  join app_private.event_route_settings cfg on cfg.event_id=g.event_id and cfg.final_portal_id=p.id
  left join latest_runs r on r.group_id=g.id
  where s.state='published' and s.expected_finale_arrival_at is not null and p.operation_status in ('scheduled','open')
    and coalesce(r.status::text,'') not in ('completed','stopped')
    and not exists(select 1 from app_private.group_start_publications pub join app_private.finale_publication_commitments c on c.publication_id=pub.id where pub.schedule_id=s.id)
    and not exists(select 1 from app_private.portal_reservations b where b.group_id=g.id and b.portal_id=p.id and b.status in ('held','active','completed'))
 ), deduplicated as (
  select distinct on(group_id) * from raw_arrivals order by group_id,priority,planned_arrival_at desc,reservation_id
 ), enriched as (
  select d.*,coalesce(d.children,(select count(*)::integer from app_private.group_registrations a join app_private.registration_children c
    on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=d.group_id and a.superseded_at is null)) expected_children from deduplicated d
 )
 select jsonb_build_object('portalId',p.id,'portalCode',p.system_code,'operationStatus',p.operation_status,'updatedAt',clock_timestamp(),
  'forecastAvailable',exists(select 1 from app_private.event_route_settings cfg where cfg.event_id=p.event_id and cfg.final_portal_id=p.id),
  'nextArrivalAt',(select min(planned_arrival_at) from enriched where state<>'completed'),
  'arrivals',coalesce((select jsonb_agg(jsonb_build_object('groupCode',e.group_code,'systemCode',e.group_code,
    'plannedArrivalAt',e.planned_arrival_at,'plannedDepartureAt',e.planned_departure_at,'expectedChildren',e.expected_children,'state',e.state,'classification',e.classification,
    'reservationId',e.reservation_id,'publicationId',e.publication_id,'revision',e.publication_revision) order by e.planned_arrival_at,e.group_code) from enriched e),'[]'::jsonb),
  'assignedGroups',(select count(*) from enriched where classification='assigned' and state<>'completed'),
  'assignedChildren',coalesce((select sum(expected_children) from enriched where classification='assigned' and state<>'completed'),0),
  'forecastGroups',(select count(*) from enriched where classification='forecast' and state<>'completed'),
  'forecastChildren',coalesce((select sum(expected_children) from enriched where classification='forecast' and state<>'completed'),0),
  'completedGroups',(select count(*) from enriched where state='completed'),'remainingGroups',(select count(*) from enriched where state<>'completed'),
  'expectedTotal',coalesce((select sum(expected_children) from enriched where state<>'completed'),0))
 );
end;
$function$;

