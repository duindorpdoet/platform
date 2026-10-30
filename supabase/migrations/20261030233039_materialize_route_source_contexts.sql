-- Preserve every canonical hash field and ordering, while evaluating each
-- group's start context once per statement. A pull-up-able LATERAL SELECT allowed
-- the optimizer to repeat the context function for each JSON field reference.
-- MATERIALIZED is statement-local only: later statements always see new inputs.
-- CREATE OR REPLACE preserves owner and existing execute ACLs.
create or replace function app_private.joint_route_source_hash_before_v3(_event uuid) returns text
language sql stable security definer set search_path='' as $$
 with group_contexts as materialized (
  select g.id,app_private.route_group_start_context(g.id) value
  from app_private.walking_groups g where g.event_id=_event
 )
 select encode(extensions.digest(convert_to(jsonb_build_object(
  'policyVersion',2,
  'event',(select jsonb_build_array(e.settings,e.local_date) from app_private.events e where e.id=_event),
  'settings',(select to_jsonb(s)-array['version','updated_at','updated_by'] from app_private.event_route_settings s where s.event_id=_event),
  'groups',(select jsonb_agg(jsonb_build_array(g.id,g.retired_at,
    app_private.start_group_composition_hash(g.id),app_private.group_ordinary_deadline(g.id),
    ctx.value->'scheduleId',ctx.value->'planId',ctx.value->'startsAt',ctx.value->'expectedFinaleArrivalAt',
    coalesce(nullif(ctx.value->'pointSnapshot','null'::jsonb),'{}'::jsonb)-array['version','updated_at','updated_by','created_at','created_by'],
    coalesce(nullif(ctx.value->'slotSnapshot','null'::jsonb),'{}'::jsonb)-array['version','updated_at','updated_by','created_at','created_by'],
    (select jsonb_build_array(p.active,p.accessible,p.available_from,p.available_until,p.max_gathering_groups,p.max_gathering_children) from app_private.start_points p where p.id=(ctx.value#>>'{pointSnapshot,id}')::uuid),
    (select jsonb_build_array(s.active,s.max_groups,s.max_children)from app_private.start_slots s where s.id=(ctx.value#>>'{slotSnapshot,id}')::uuid)) order by g.id)
   from app_private.walking_groups g join group_contexts ctx on ctx.id=g.id where g.event_id=_event),
  'children',(select jsonb_agg(jsonb_build_array(rc.id,rc.participation_status,c.id,c.step_free_required,app_private.child_step_free_requirement(c.id)) order by rc.id)
   from app_private.registrations r join app_private.registration_children rc on rc.registration_id=r.id join app_private.children c on c.id=rc.child_id where r.event_id=_event and exists(select 1 from app_private.group_registrations assigned join app_private.walking_groups ag on ag.id=assigned.group_id and ag.retired_at is null where assigned.registration_id=r.id and assigned.superseded_at is null)),
  'registrations',(select jsonb_agg(jsonb_build_array(r.id,r.status,r.preferred_start_at,r.desired_end_at,r.requested_ordinary_stop_at) order by r.id) from app_private.registrations r where r.event_id=_event and exists(select 1 from app_private.group_registrations assigned join app_private.walking_groups ag on ag.id=assigned.group_id and ag.retired_at is null where assigned.registration_id=r.id and assigned.superseded_at is null)),
  'portals',(select jsonb_agg(jsonb_build_array(p.id,app_private.portal_physical_identity(p.id),p.lifecycle_status,p.approval_status,p.operation_status,
    p.arrival_headway_seconds,p.ordinary_end_grace_seconds,p.ordinary_hard_close,app_private.routing_coordinate(app_private.portal_location(p.id)),
    app_private.portal_accessibility_status(p.id),
    (select jsonb_agg(jsonb_build_array(w.opens_at,w.closes_at,w.visit_minutes,w.buffer_minutes,w.max_concurrent_groups,w.max_children_per_visit,w.max_children_total) order by w.opens_at,w.closes_at,w.id) from app_private.portal_windows w where w.portal_id=p.id)) order by p.id) from app_private.portals p where p.event_id=_event),
  'nodes',(select jsonb_agg(to_jsonb(n) order by n.id) from app_private.walking_nodes n where n.event_id=_event),
  'edges',(select jsonb_agg(to_jsonb(e) order by e.id) from app_private.walking_edges e where e.event_id=_event)
 )::text,'UTF8'),'sha256'),'hex')
$$;
