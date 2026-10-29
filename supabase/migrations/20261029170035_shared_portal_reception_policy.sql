-- Shared physical reception policy. Adding defaults does not rewrite publications,
-- accepted intentions, runs, child declarations or old portal application data.
set lock_timeout='5s';
alter table app_private.portals
 add column arrival_headway_seconds integer not null default 300 check(arrival_headway_seconds between 300 and 3600 and arrival_headway_seconds%60=0),
 add column ordinary_end_grace_seconds integer not null default 300 check(ordinary_end_grace_seconds between 0 and 300),
 add column ordinary_hard_close boolean not null default false,
 add column accessibility_status text check(accessibility_status in ('unknown','step_free','not_step_free'));
alter table app_private.children add column step_free_required boolean;

create function app_private.child_step_free_requirement(_child uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select case when c.step_free_required is not null then c.step_free_required
  when nullif(trim(c.accessibility_note),'') is null then false else null end
 from app_private.children c where c.id=_child
$$;
create function app_private.portal_accessibility_status(_portal uuid) returns text
language sql stable security definer set search_path='' as $$
 select coalesce(p.accessibility_status,case a.private_draft_data->>'accessibility'
  when 'step_free' then 'step_free' when 'steps' then 'not_step_free' else 'unknown' end)
 from app_private.portals p left join app_private.portal_applications a on a.id=p.application_id where p.id=_portal
$$;

create function app_private.portal_physical_identity(_portal uuid) returns uuid
language sql stable security definer set search_path='' as $$
 select coalesce(p.application_id,p.id) from app_private.portals p where p.id=_portal
$$;
-- Proven duplicate records may not offer conflicting physical limits. A
-- configuration conflict requires explicit review instead of selecting the more
-- permissive record. Different headways safely share the strictest distance.
create function app_private.portal_physical_policy_consistent(_portal uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select count(distinct jsonb_build_array(p.ordinary_end_grace_seconds,p.ordinary_hard_close,app_private.portal_accessibility_status(p.id),p.operation_status,
  (select jsonb_agg(jsonb_build_array(w.opens_at,w.closes_at,w.visit_minutes,w.buffer_minutes,w.max_concurrent_groups,w.max_children_per_visit,w.max_children_total)order by w.opens_at,w.closes_at,w.id)from app_private.portal_windows w where w.portal_id=p.id)))<=1
 from app_private.portals source join app_private.portals p on p.event_id=source.event_id and coalesce(p.application_id,p.id)=coalesce(source.application_id,source.id)
 where source.id=_portal and p.lifecycle_status='active'and p.approval_status='approved'
$$;

-- Arrival is strictly before an ordinary receiving window closes. Only physical
-- service plus changeover can extend by the explicitly allowed ordinary grace.
-- A finale always intersects the actual portal window with its separate show window.
create function app_private.portal_effective_windows(_portal uuid)
returns table(opens_at timestamptz,arrival_closes_at timestamptz,closes_at timestamptz,
 visit_seconds integer,buffer_seconds integer,max_groups integer,max_children integer,
 max_total_children integer,headway_seconds integer,is_finale boolean,max_concurrent_children integer)
language sql stable security definer set search_path='' as $$
 select case when app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(s.final_portal_id) then greatest(w.opens_at,s.finale_opens_at) else w.opens_at end,
  case when app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(s.final_portal_id) then least(s.finale_last_arrival_at,
   least(w.closes_at,s.finale_closes_at)-make_interval(secs=>s.finale_show_seconds+s.finale_turnover_seconds)) else w.closes_at end,
  case when app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(s.final_portal_id) then least(w.closes_at,s.finale_closes_at)
   else w.closes_at+make_interval(secs=>case when p.ordinary_hard_close then 0 else p.ordinary_end_grace_seconds end) end,
  case when app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(s.final_portal_id) then s.finale_show_seconds else w.visit_minutes*60 end,
  case when app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(s.final_portal_id) then s.finale_turnover_seconds else w.buffer_minutes*60 end,
  case when app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(s.final_portal_id) then least(w.max_concurrent_groups,s.finale_max_concurrent_groups) else w.max_concurrent_groups end,
  case when app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(s.final_portal_id) then least(w.max_children_per_visit,s.finale_max_concurrent_children) else w.max_children_per_visit end,
  w.max_children_total,(select max(alias.arrival_headway_seconds)from app_private.portals alias where alias.event_id=p.event_id and coalesce(alias.application_id,alias.id)=coalesce(p.application_id,p.id)),coalesce(app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(s.final_portal_id),false),
  case when app_private.portal_physical_identity(p.id)=app_private.portal_physical_identity(s.final_portal_id) then s.finale_max_concurrent_children else null end
 from app_private.portals p join app_private.portal_windows w on w.portal_id=p.id
 left join app_private.event_route_settings s on s.event_id=p.event_id
 where p.id=_portal and app_private.portal_physical_policy_consistent(p.id) order by w.opens_at,w.id
$$;
create function app_private.group_ordinary_deadline(_group uuid) returns timestamptz
language sql stable security definer set search_path='' as $$
 select least(s.global_ordinary_stop_at,
  coalesce((select min(r.requested_ordinary_stop_at) from app_private.group_registrations a
   join app_private.registrations r on r.id=a.registration_id where a.group_id=g.id and a.superseded_at is null
   and r.status='submitted' and r.requested_ordinary_stop_at is distinct from r.desired_end_at),s.global_ordinary_stop_at))
 from app_private.walking_groups g join app_private.event_route_settings s on s.event_id=g.event_id where g.id=_group
$$;

-- One source for an effective departure: a public appointment keeps its frozen
-- point, while an unpublished appointment uses the current checked point.
create function app_private.route_group_start_context(_group uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('scheduleId',s.id,'planId',case when s.id is null then g.current_plan_version_id end,
  'startsAt',coalesce(pub.starts_at,slot.starts_at),'pointSnapshot',coalesce(pub.point_snapshot,to_jsonb(point)),
  'slotSnapshot',coalesce(pub.slot_snapshot,to_jsonb(slot)),'expectedFinaleArrivalAt',s.expected_finale_arrival_at,
  'hasPublishedStart',pub.id is not null)
 from app_private.walking_groups g left join lateral app_private.current_start_publication(g.id) pub on true
 left join app_private.group_schedule_revisions s on s.id=coalesce(pub.schedule_id,g.current_schedule_revision_id)
 left join app_private.start_slots slot on slot.id=coalesce(s.start_slot_id,g.start_slot_id)
 left join app_private.start_points point on point.id=slot.start_point_id where g.id=_group
$$;


-- Semantic immutable inputs exclude publication/audit metadata and normal live
-- progress. Publishing the same checked appointment leaves this hash unchanged.
create function app_private.joint_route_source_hash(_event uuid) returns text
language sql stable security definer set search_path='' as $$
 select encode(extensions.digest(convert_to(jsonb_build_object(
  'policyVersion',1,
  'event',(select jsonb_build_array(e.settings,e.local_date) from app_private.events e where e.id=_event),
  'settings',(select to_jsonb(s)-array['version','updated_at','updated_by'] from app_private.event_route_settings s where s.event_id=_event),
  'groups',(select jsonb_agg(jsonb_build_array(g.id,g.retired_at,g.desired_ordinary_visits,
    app_private.start_group_composition_hash(g.id),app_private.group_ordinary_deadline(g.id),
    ctx.value->'scheduleId',ctx.value->'planId',ctx.value->'startsAt',ctx.value->'expectedFinaleArrivalAt',
    coalesce(nullif(ctx.value->'pointSnapshot','null'::jsonb),'{}'::jsonb)-array['version','updated_at','updated_by','created_at','created_by'],
    coalesce(nullif(ctx.value->'slotSnapshot','null'::jsonb),'{}'::jsonb)-array['version','updated_at','updated_by','created_at','created_by'],
    (select jsonb_build_array(p.active,p.accessible,p.available_from,p.available_until,p.max_gathering_groups,p.max_gathering_children) from app_private.start_points p where p.id=(ctx.value#>>'{pointSnapshot,id}')::uuid),
    (select jsonb_build_array(s.active,s.max_groups,s.max_children)from app_private.start_slots s where s.id=(ctx.value#>>'{slotSnapshot,id}')::uuid)) order by g.id)
   from app_private.walking_groups g cross join lateral(select app_private.route_group_start_context(g.id) value) ctx where g.event_id=_event),
  'children',(select jsonb_agg(jsonb_build_array(rc.id,rc.participation_status,c.id,c.step_free_required,app_private.child_step_free_requirement(c.id)) order by rc.id)
   from app_private.registrations r join app_private.registration_children rc on rc.registration_id=r.id join app_private.children c on c.id=rc.child_id where r.event_id=_event and exists(select 1 from app_private.group_registrations assigned join app_private.walking_groups ag on ag.id=assigned.group_id and ag.retired_at is null where assigned.registration_id=r.id and assigned.superseded_at is null)),
  'registrations',(select jsonb_agg(jsonb_build_array(r.id,r.status,r.preferred_start_at,r.desired_end_at,r.requested_ordinary_stop_at) order by r.id) from app_private.registrations r where r.event_id=_event and exists(select 1 from app_private.group_registrations assigned join app_private.walking_groups ag on ag.id=assigned.group_id and ag.retired_at is null where assigned.registration_id=r.id and assigned.superseded_at is null)),
  'portals',(select jsonb_agg(jsonb_build_array(p.id,app_private.portal_physical_identity(p.id),p.world_id,p.lifecycle_status,p.approval_status,p.operation_status,
    p.arrival_headway_seconds,p.ordinary_end_grace_seconds,p.ordinary_hard_close,app_private.routing_coordinate(app_private.portal_location(p.id)),
    app_private.portal_accessibility_status(p.id),
    (select jsonb_agg(jsonb_build_array(w.opens_at,w.closes_at,w.visit_minutes,w.buffer_minutes,w.max_concurrent_groups,w.max_children_per_visit,w.max_children_total) order by w.opens_at,w.closes_at,w.id) from app_private.portal_windows w where w.portal_id=p.id)) order by p.id) from app_private.portals p where p.event_id=_event),
  'nodes',(select jsonb_agg(to_jsonb(n) order by n.id) from app_private.walking_nodes n where n.event_id=_event),
  'edges',(select jsonb_agg(to_jsonb(e) order by e.id) from app_private.walking_edges e where e.event_id=_event),
  'compensation',jsonb_build_array(app_private.world_coverage_current_version(_event),app_private.world_coverage_missing(_event))
 )::text,'UTF8'),'sha256'),'hex')
$$;
create or replace function app_private.start_ops_route_revision(_event_id uuid) returns integer
language sql stable security definer set search_path='' as $$
 select ('x'||substr(app_private.joint_route_source_hash(_event_id),1,7))::bit(28)::integer
$$;

create function app_private.portal_planning_policy(_portal uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('arrivalHeadwaySeconds',p.arrival_headway_seconds,'ordinaryEndGraceSeconds',p.ordinary_end_grace_seconds,
  'ordinaryHardClose',p.ordinary_hard_close,'accessibilityStatus',app_private.portal_accessibility_status(p.id),'planningPolicyVersion',p.version,'isFinale',exists(select 1 from app_private.event_route_settings s where s.event_id=p.event_id and app_private.portal_physical_identity(s.final_portal_id)=app_private.portal_physical_identity(p.id)))
 from app_private.portals p where p.id=_portal
$$;
create function app_private.portal_planning_policy_can_manage(_portal uuid,_actor uuid default auth.uid()) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce(_actor is not null and (app_private.has_capability(p.event_id,'event_admin',_actor)
  or app_private.has_capability(p.event_id,'portals_manage',_actor)
  or exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.user_id=_actor and o.revoked_at is null and o.suspended_at is null and o.access_level='manage')),false)
 from app_private.portals p where p.id=_portal
$$;
create function app_private.validate_portal_planning_policy(_payload jsonb) returns void
language plpgsql immutable set search_path='' as $$
begin
 if jsonb_typeof(_payload) is distinct from 'object'
  or (_payload?'arrivalHeadwaySeconds' and (jsonb_typeof(_payload->'arrivalHeadwaySeconds') is distinct from 'number' or (_payload->>'arrivalHeadwaySeconds')::numeric not between 300 and 3600 or mod((_payload->>'arrivalHeadwaySeconds')::numeric,60)<>0))
  or (_payload?'ordinaryEndGraceSeconds' and (jsonb_typeof(_payload->'ordinaryEndGraceSeconds') is distinct from 'number' or (_payload->>'ordinaryEndGraceSeconds')::numeric not between 0 and 300 or mod((_payload->>'ordinaryEndGraceSeconds')::numeric,1)<>0))
  or (_payload?'ordinaryHardClose' and jsonb_typeof(_payload->'ordinaryHardClose') is distinct from 'boolean')
  or (_payload?'accessibilityStatus' and (jsonb_typeof(_payload->'accessibilityStatus') is distinct from 'string' or _payload->>'accessibilityStatus' not in ('unknown','step_free','not_step_free')))
 then raise exception 'INVALID_PLANNING_POLICY' using errcode='22023'; end if;
end $$;
create function app_private.apply_portal_planning_policy(_portal uuid,_payload jsonb) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.validate_portal_planning_policy(_payload);
 update app_private.portals set
  arrival_headway_seconds=case when _payload?'arrivalHeadwaySeconds' then (_payload->>'arrivalHeadwaySeconds')::integer else arrival_headway_seconds end,
  ordinary_end_grace_seconds=case when _payload?'ordinaryEndGraceSeconds' then (_payload->>'ordinaryEndGraceSeconds')::integer else ordinary_end_grace_seconds end,
  ordinary_hard_close=case when _payload?'ordinaryHardClose' then (_payload->>'ordinaryHardClose')::boolean else ordinary_hard_close end,
  accessibility_status=case when _payload?'accessibilityStatus' then _payload->>'accessibilityStatus' else accessibility_status end
 where id=_portal;
end $$;

create function api.portal_planning_policy_save(_portal_id uuid,_expected_version integer,_payload jsonb,_idempotency_key text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.portals; hashed text; receipt app_private.command_receipts; result jsonb;
begin
 select * into p from app_private.portals where id=_portal_id;
 if not coalesce(app_private.portal_planning_policy_can_manage(_portal_id),false) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform app_private.poortkamer_require(_portal_id,'details');
 perform 1 from app_private.events where id=p.event_id for no key update;
 perform pg_advisory_xact_lock(hashtextextended(p.event_id::text||':route-dispatch',0));
 if length(coalesce(_idempotency_key,'')) not between 16 and 200 then raise exception 'INVALID_INPUT' using errcode='22023'; end if;
 hashed:=encode(extensions.digest(jsonb_build_array(_portal_id,_expected_version,_payload)::text,'sha256'),'hex');
 select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.planning_policy' and idempotency_key=_idempotency_key;
 if found then if receipt.request_hash<>hashed then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505'; end if; return receipt.safe_result; end if;
 select * into p from app_private.portals where id=_portal_id for update;
 if p.version is distinct from _expected_version then raise exception 'STALE_VERSION' using errcode='40001'; end if;
 perform app_private.validate_portal_planning_policy(_payload);
 if app_private.portal_destination_in_use(p.id) and (app_private.portal_planning_policy(p.id)-'planningPolicyVersion') is distinct from
  ((app_private.portal_planning_policy(p.id)-'planningPolicyVersion')||(_payload-'planningPolicyVersion')) then raise exception 'RESOLVE_ACTIVE_VISITS_FIRST' using errcode='23514'; end if;
 if (app_private.portal_planning_policy(p.id)||_payload) is not distinct from app_private.portal_planning_policy(p.id) then
  result:=jsonb_build_object('id',p.id,'version',p.version,'changed',false)||app_private.portal_planning_policy(p.id);
 else
 perform app_private.apply_portal_planning_policy(p.id,_payload);
 update app_private.portals set version=version+1 where id=p.id returning * into p;
 result:=jsonb_build_object('id',p.id,'version',p.version,'changed',true)||app_private.portal_planning_policy(p.id);
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
 values(p.event_id,auth.uid(),'portal.planning_policy.changed','portal',p.id,_payload);
 perform app_private.poortkamer_signal(p.id,'portal.planning_policy.changed','{}','Het ontvangstbeleid is bijgewerkt; controleer een nieuw gezamenlijk routevoorstel.');
 end if;
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(auth.uid(),'portal.planning_policy',_idempotency_key,hashed,result,now()+interval '30 days');
 return result;
end $$;
revoke all on function api.portal_planning_policy_save(uuid,integer,jsonb,text) from public,anon;
grant execute on function api.portal_planning_policy_save(uuid,integer,jsonb,text) to authenticated;

alter function api.portal_room_snapshot(text,uuid) rename to portal_room_snapshot_before_reception_policy;
revoke all on function api.portal_room_snapshot_before_reception_policy(text,uuid) from public,anon,authenticated;
create function api.portal_room_snapshot(_event_slug text,_portal_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; pid uuid;
begin
 result:=api.portal_room_snapshot_before_reception_policy(_event_slug,_portal_id);pid:=(result#>>'{portal,id}')::uuid;
 if pid is null then return result; end if;
 result:=jsonb_set(result,'{portal}',(result->'portal')||app_private.portal_planning_policy(pid)||jsonb_build_object('canManagePlanningPolicy',app_private.portal_planning_policy_can_manage(pid)));
 return result||jsonb_build_object('canManagePlanningPolicy',app_private.portal_planning_policy_can_manage(pid));
end $$;
revoke all on function api.portal_room_snapshot(text,uuid) from public,anon;
grant execute on function api.portal_room_snapshot(text,uuid) to authenticated;

alter function api.admin_portal_records_snapshot(text) rename to admin_portal_records_snapshot_before_reception_policy;
revoke all on function api.admin_portal_records_snapshot_before_reception_policy(text) from public,anon,authenticated;
create function api.admin_portal_records_snapshot(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 result:=api.admin_portal_records_snapshot_before_reception_policy(_event_slug);
 return jsonb_set(result,'{portals}',coalesce((select jsonb_agg(item||app_private.portal_planning_policy((item->>'id')::uuid)) from jsonb_array_elements(result->'portals') item),'[]'));
end $$;
revoke all on function api.admin_portal_records_snapshot(text) from public,anon;
grant execute on function api.admin_portal_records_snapshot(text) to authenticated;

alter function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) rename to admin_manual_portal_save_before_reception_policy;
revoke all on function api.admin_manual_portal_save_before_reception_policy(text,uuid,jsonb,integer,text) from public,anon,authenticated;
create function api.admin_manual_portal_save(_event_slug text,_portal_id uuid,_payload jsonb,_expected_version integer,_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; replay boolean; eid uuid;
begin
 perform app_private.validate_portal_planning_policy(_payload);
 select id into eid from app_private.events where slug=_event_slug for no key update;
 if auth.uid() is null or eid is null or not(app_private.has_capability(eid,'portals_manage',auth.uid()) or app_private.has_capability(eid,'event_admin',auth.uid())) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(eid::text||':route-dispatch',0));
 select exists(select 1 from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.manual.save' and idempotency_key=_payload->>'commandKey') into replay;
 if not replay and _portal_id is not null and coalesce(_payload->>'saveMode','')<>'draft' and app_private.portal_destination_in_use(_portal_id)
  and (app_private.portal_planning_policy(_portal_id)-'planningPolicyVersion') is distinct from
   ((app_private.portal_planning_policy(_portal_id)-'planningPolicyVersion')||jsonb_strip_nulls(jsonb_build_object('arrivalHeadwaySeconds',_payload->'arrivalHeadwaySeconds','ordinaryEndGraceSeconds',_payload->'ordinaryEndGraceSeconds','ordinaryHardClose',_payload->'ordinaryHardClose','accessibilityStatus',_payload->'accessibilityStatus')))
 then raise exception 'RESOLVE_ACTIVE_VISITS_FIRST' using errcode='23514'; end if;
 result:=api.admin_manual_portal_save_before_reception_policy(_event_slug,_portal_id,_payload,_expected_version,_reason);
 if not replay and coalesce(_payload->>'saveMode','')<>'draft' then perform app_private.apply_portal_planning_policy((result->>'id')::uuid,_payload); end if;
 return result;
end $$;
revoke all on function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) from public,anon;
grant execute on function api.admin_manual_portal_save(text,uuid,jsonb,integer,text) to authenticated;

revoke all on function app_private.portal_physical_policy_consistent(uuid),app_private.route_group_start_context(uuid),app_private.portal_physical_identity(uuid),app_private.child_step_free_requirement(uuid),app_private.portal_accessibility_status(uuid),app_private.portal_effective_windows(uuid),app_private.group_ordinary_deadline(uuid),app_private.joint_route_source_hash(uuid),app_private.start_ops_route_revision(uuid),app_private.portal_planning_policy(uuid),app_private.portal_planning_policy_can_manage(uuid,uuid),app_private.validate_portal_planning_policy(jsonb),app_private.apply_portal_planning_policy(uuid,jsonb) from public,anon,authenticated;
