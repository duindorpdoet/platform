begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(not has_table_privilege('authenticated','app_private.location_change_history','select'),
  'location history is never directly readable through an authenticated client');
select ok(not has_table_privilege('authenticated','app_private.start_planning_versions','select'),
  'planning versions are exposed only through capability-checked RPCs');
select ok(not has_function_privilege('anon','api.admin_startregie_snapshot(text)','execute'),
  'anonymous visitors cannot open Startregie');
select ok(has_function_privilege('authenticated','api.admin_startregie_snapshot(text)','execute'),
  'authenticated users can reach the capability-checked Startregie contract');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok(
  $$select api.admin_startregie_snapshot('duindorp-halloween-2026')$$,
  '42501','NOT_AUTHORIZED','a participant cannot inspect private planning locations'
);

set local role postgres;
create temporary table startregie_state(
  start_point_id uuid,
  start_point_version integer,
  world_slug text,
  concept_portal_id uuid,
  concept_portal_version integer,
  active_portal_id uuid,
  active_portal_version integer,
  final_portal_id uuid,
  final_portal_version integer
) on commit drop;
insert into startregie_state(world_slug)
select slug from app_private.worlds
where event_id=(select id from app_private.events where slug='duindorp-halloween-2026')
order by sort_order limit 1;
grant select, update on startregie_state to authenticated;

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok(
  $$select api.admin_startregie_snapshot('duindorp-halloween-2026')$$,
  'an event administrator can load the operational Startregie snapshot'
);
select is(
  jsonb_typeof(api.admin_startregie_snapshot('duindorp-halloween-2026')->'warnings'),
  'array','Startregie returns actionable warnings as a stable array'
);

update startregie_state set
  start_point_id = created.id,
  start_point_version = created.version
from lateral (
  select (result->>'id')::uuid id, (result->>'version')::integer version
  from (select api.admin_startregie_start_point_save(
    'duindorp-halloween-2026', null,
    jsonb_build_object(
      'name','Hof Zuid','publicLabel','Hof Zuid','pointType','gathering',
      'privateAddress','', 'publicArrivalInstructions','Verzamel bij de zuidelijke ingang',
      'markerLatitude','52.100150','markerLongitude','4.270150','markerReason','Ingang hof aan zuidzijde',
      'maxGroups',2,'maxChildren',24,'active',true
    ), null, 'Zelfstandig startpunt zonder straatadres aangemaakt'
  ) result) call
) created;

set local role postgres;
select is(
  (select private_address from app_private.start_points where id=(select start_point_id from startregie_state)),
  null,'a standalone gathering point can be created without an official address'
);
select ok(
  (select walking_node_id is not null from app_private.start_points where id=(select start_point_id from startregie_state)),
  'the nearest verified walking node is calculated when the marker is saved'
);

set local role authenticated;
select lives_ok(
  $$select api.admin_location_marker_save(
    'duindorp-halloween-2026','start_point',(select start_point_id from startregie_state),
    52.100250,4.270250,'Ingang ligt aan de veilige zuidzijde',false,
    (select start_point_version from startregie_state)
  )$$,
  'an authorized organizer can move only the routing marker'
);
set local role postgres;
select is(
  (select private_address from app_private.start_points where id=(select start_point_id from startregie_state)),
  null,'moving a marker never rewrites the official address'
);
select ok(
  exists(select 1 from app_private.location_change_history where resource_id=(select start_point_id from startregie_state)),
  'marker changes are retained in the private audit history'
);

set local role authenticated;
update startregie_state set concept_portal_id = created.id, concept_portal_version = created.version
from lateral (
  select (result->>'id')::uuid id, (result->>'version')::integer version
  from (select api.admin_manual_portal_save(
    'duindorp-halloween-2026',null,
    jsonb_build_object(
      'name','Conceptpoort Handmatig','worldSlug',(select world_slug from startregie_state),
      'lifecycleStatus','concept','intensity',1,'candidateStartPoint',false
    ),null,'Ongebruikte conceptpoort handmatig toegevoegd'
  ) result) call
) created;
select is(
  (api.admin_manual_portal_remove(
    (select concept_portal_id from startregie_state),(select concept_portal_version from startregie_state),
    'Ongebruikte conceptpoort na controle verwijderd'
  )->>'deleted')::boolean,
  true,'an unused manual concept portal is permanently removable'
);

update startregie_state set active_portal_id = created.id, active_portal_version = created.version
from lateral (
  select (result->>'id')::uuid id, (result->>'version')::integer version
  from (select api.admin_manual_portal_save(
    'duindorp-halloween-2026',null,
    jsonb_build_object(
      'name','Actieve Handpoort','worldSlug',(select world_slug from startregie_state),
      'lifecycleStatus','active','approvalStatus','approved','intensity',2,'latitude',52.1003,'longitude',4.2703,
      'street','Teststraat','houseNumber','9','postalCode','2584 ZZ','city','Den Haag',
      'plannedOpensAt','2026-10-31T17:00:00+01:00','plannedClosesAt','2026-10-31T22:00:00+01:00',
      'maxGroups',2,'maxChildren',24,'candidateStartPoint',true
    ),null,'Actieve poort handmatig geregistreerd en gecontroleerd'
  ) result) call
) created;
set local role postgres;
select is(
  (select record_source from app_private.portals where id=(select active_portal_id from startregie_state)),
  'manual','a manual portal retains its origin independently of future ownership'
);
update startregie_state state set
  start_point_version = (select version from app_private.start_points where id=state.start_point_id);
set local role authenticated;
select is(
  (api.admin_manual_portal_remove(
    (select active_portal_id from startregie_state),(select active_portal_version from startregie_state),
    'Gebruikte actieve poort veilig uit de planning gehaald'
  )->>'archived')::boolean,
  true,'a non-concept portal is archived instead of hard deleted'
);

set local role postgres;
update app_private.event_route_settings settings set final_portal_id = (
  select candidate.id from app_private.portals candidate
  where candidate.event_id=settings.event_id and candidate.lifecycle_status='active'
  order by candidate.system_number limit 1
)
where settings.event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
update startregie_state state set final_portal_id=settings.final_portal_id, final_portal_version=portal.version
from app_private.event_route_settings settings
join app_private.events event on event.id=settings.event_id and event.slug='duindorp-halloween-2026'
join app_private.portals portal on portal.id=settings.final_portal_id;
set local role authenticated;
select throws_ok(
  $$select api.admin_manual_portal_remove(
    (select final_portal_id from startregie_state),(select final_portal_version from startregie_state),
    'Poging eindpoort zonder vervanging te verwijderen'
  )$$,
  '23514','CHOOSE_REPLACEMENT_FINAL_PORTAL_FIRST','the final portal cannot be removed without choosing a replacement'
);

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok(
  $$select api.admin_location_marker_save(
    'duindorp-halloween-2026','start_point',(select start_point_id from startregie_state),
    52.1004,4.2704,'Onbevoegde markerwijziging geblokkeerd',false,
    (select start_point_version from startregie_state)
  )$$,
  '42501','NOT_AUTHORIZED','RLS-style capability checks block unauthorized location mutations'
);

select * from finish();
rollback;
