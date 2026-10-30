begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- Exact pre-hotfix implementation is a test-only reference. Equality includes
-- all children, registrations, retired groups, portal windows and coordinates.
create function pg_temp.reference_joint_route_source_hash(_event uuid) returns text
language sql stable security definer set search_path='' as $$
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
   from app_private.walking_groups g cross join lateral(select app_private.route_group_start_context(g.id) value) ctx where g.event_id=_event),
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
create temp table materialized_hash_fixture as
 select e.id event_id, app_private.joint_route_source_hash_before_v3(e.id) initial_hash
 from app_private.events e where e.slug='duindorp-halloween-2026';
select is(app_private.joint_route_source_hash_before_v3(event_id),
 pg_temp.reference_joint_route_source_hash(event_id),
 'materialized context preserves the exact original canonical hash')
 from materialized_hash_fixture;
select is(app_private.joint_route_source_hash_before_v3(null::uuid),
 pg_temp.reference_joint_route_source_hash(null::uuid),
 'an absent event preserves the original empty/null-field hash');

-- A temporary canonical-input change proves both equality and freshness.
update app_private.event_route_settings set route_buffer_seconds=route_buffer_seconds+1
 where event_id=(select event_id from materialized_hash_fixture);
select is(app_private.joint_route_source_hash_before_v3(event_id),
 pg_temp.reference_joint_route_source_hash(event_id),
 'a changed route setting retains exact canonical equality')
 from materialized_hash_fixture;
select isnt(app_private.joint_route_source_hash_before_v3(event_id),initial_hash,
 'a later statement sees changed inputs without transaction-local caching')
 from materialized_hash_fixture;

create temp table materialized_portal_fixture as
 select id,arrival_headway_seconds
 from app_private.portals where event_id=(select event_id from materialized_hash_fixture)
 order by id limit 1;
update app_private.portals p set arrival_headway_seconds=case when p.arrival_headway_seconds<3600 then p.arrival_headway_seconds+60 else p.arrival_headway_seconds-60 end
 from materialized_portal_fixture fixture where p.id=fixture.id;
select is(app_private.joint_route_source_hash_before_v3(event_id),
 pg_temp.reference_joint_route_source_hash(event_id),
 'portal reception-policy changes retain exact canonical equality')
 from materialized_hash_fixture;

select ok(not has_function_privilege('anon',
 'app_private.joint_route_source_hash_before_v3(uuid)','EXECUTE'),
 'anonymous users still cannot access private route inputs');
select ok(not has_function_privilege('authenticated',
 'app_private.joint_route_source_hash_before_v3(uuid)','EXECUTE'),
 'the existing private execute ACL remains unchanged');

-- Regression contract for the original cause: each group's start context is
-- evaluated in one materialized relation, never once per expanded JSON field.
select is((select cardinality(string_to_array(prosrc,'route_group_start_context(g.id)'))-1
 from pg_proc where oid='app_private.joint_route_source_hash_before_v3(uuid)'::regprocedure),1,
 'there is one start-context expression independent of JSON field count');
select ok((select prosrc ilike '%group_contexts as materialized%'
 from pg_proc where oid='app_private.joint_route_source_hash_before_v3(uuid)'::regprocedure),
 'the start-context evaluation boundary cannot be pulled up by the planner');

select * from finish();
rollback;
