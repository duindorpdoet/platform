begin;
create extension if not exists pgtap with schema extensions;
\ir fixtures/evening-route-publication.inc
select plan(15);
create function pg_temp.publish_current_schedule(_ids uuid[],_reason text) returns jsonb language plpgsql security definer set search_path='' as $$
declare expected jsonb; version integer;
begin
 select jsonb_agg(jsonb_build_object('id',id,'revision',revision) order by id) into expected from app_private.group_schedule_revisions where id=any(_ids);
 select settings_version into version from app_private.events where slug='duindorp-halloween-2026';
 return pg_temp.publish_fingerprinted('duindorp-halloween-2026',_ids,expected,version,gen_random_uuid()::text,_reason);
end $$;
grant execute on function pg_temp.publish_current_schedule(uuid[],text) to authenticated;
create function pg_temp.event_settings_version() returns integer language sql security definer set search_path='' as $$select settings_version from app_private.events where slug='duindorp-halloween-2026'$$;
grant execute on function pg_temp.event_settings_version() to authenticated;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
do $$begin perform api.admin_startregie_verify_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000001',1,true,'Fictieve veilige testaanloop via het zebrapad'); end $$;


create temporary table schedule_state(first_id uuid, correction_id uuid) on commit drop;
insert into schedule_state default values;
grant select, update on schedule_state to authenticated;

update app_private.event_route_settings set
  first_start_at = timestamptz '2026-10-31 17:30:00+01',
  global_ordinary_stop_at = timestamptz '2026-10-31 20:30:00+01',
  final_portal_id = '12000000-0000-0000-0000-000000000030',
  finale_opens_at = timestamptz '2026-10-31 19:00:00+01',
  finale_last_arrival_at = timestamptz '2026-10-31 21:30:00+01',
  finale_closes_at = timestamptz '2026-10-31 22:00:00+01',
  finale_show_seconds = 360,
  finale_turnover_seconds = 0,
  finale_max_concurrent_groups = 2,
  finale_max_concurrent_children = 20,
  finale_available = true,
  planner_mode = 'dynamic'
where event_id = (select id from app_private.events where slug = 'duindorp-halloween-2026');

with inserted as (
  insert into app_private.group_schedule_revisions(
    group_id, revision, state, start_slot_id, effective_ordinary_stop_at,
    expected_finale_arrival_at, preference_match, created_by
  ) values (
    '23000000-0000-0000-0000-000000000001', 1, 'draft',
    '20000000-0000-0000-0000-000000000001', timestamptz '2026-10-31 20:00:00+01',
    timestamptz '2026-10-31 20:15:00+01', 'neutral', 'f0000000-0000-0000-0000-000000000001'
  ) returning id
)
update schedule_state set first_id = inserted.id from inserted;
update app_private.walking_groups walking_group set route_mode = 'dynamic', status = 'draft',
  current_schedule_revision_id = state.first_id, version = version + 1
from schedule_state state where walking_group.id = '23000000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{group,start,address}',
  null::text,
  'a household cannot retrieve a concept start through the direct group API'
);

set local role postgres;
update app_private.payment_requests set status = 'awaiting_payment'
where registration_id = '22000000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
 $$select api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',1,pg_temp.event_settings_version())$$,
 'unpaid applications can confirm a valid start without altering financial status'
);

set local role postgres;
update app_private.payment_requests set status = 'confirmed'
where registration_id = '22000000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
do $$begin perform api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',1,pg_temp.event_settings_version());end $$;
select lives_ok(
  $$ select pg_temp.publish_current_schedule(
    array[(select first_id from schedule_state)],
    'Eerste groepsindeling gecontroleerd en bevestigd'
  ) $$,
  'an authorized organizer explicitly publishes the paid group schedule'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{group,start,address}',
  null::text,
  'time publication still withholds the private address before T minus 60'
);
select is(
  api.registration_preferences_snapshot('duindorp-halloween-2026') #>> '{confirmedSchedule,startsAt}',
  '2026-10-31T17:30:00+00:00',
  'Mijn inschrijving exposes the exact confirmed start in an unambiguous timestamp'
);

set local role postgres;
select is(
  (select count(*)::integer from app_private.email_outbox where payload->>'groupId'='23000000-0000-0000-0000-000000000001' and message_type in ('group_schedule_published','group_schedule_corrected')),
  1,
  'publication queues one confirmation message for each authorized adult and revision'
);

insert into app_private.start_points(
  id, event_id, name, private_address, latitude, longitude, walking_node_id,
  max_gathering_groups, max_gathering_children, verified_at, verified_by
)
select '20000000-0000-0000-0000-000000000002', event.id, 'Teststart 2', 'TWEEDE BESLOTEN TESTADRES',
  52.1, 4.27, '13000000-0000-0000-0000-000000000999', 10, 100, now(),
  'f0000000-0000-0000-0000-000000000001'
from app_private.events event where event.slug = 'duindorp-halloween-2026';
insert into app_private.start_slots(
  id, event_id, name, location_name, private_address, latitude, longitude,
  location_verified_at, starts_at, max_groups, max_children, start_point_id
)
select '20000000-0000-0000-0000-000000000012', event.id, 'Teststart 2 17:30', 'Teststart 2',
  'TWEEDE BESLOTEN TESTADRES', 52.1, 4.27, now(), timestamptz '2026-10-31 17:30:00+01',
  10, 100, '20000000-0000-0000-0000-000000000002'
from app_private.events event where event.slug = 'duindorp-halloween-2026';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
do $$begin perform api.admin_startregie_verify_point('duindorp-halloween-2026','20000000-0000-0000-0000-000000000002',1,true,'Tweede fictieve veilige testaanloop via het zebrapad');end $$;
select lives_ok(
  $$ update schedule_state set correction_id = (
    api.admin_save_group_schedule(
      '23000000-0000-0000-0000-000000000001',
      '20000000-0000-0000-0000-000000000012',
      timestamptz '2026-10-31 20:00:00+01', timestamptz '2026-10-31 20:15:00+01',
      null, 'good', 'Startpunt gecorrigeerd na afstemming met het gezin'
    ) ->> 'id'
  )::uuid $$,
  'a later correction creates a new draft revision for only the affected group'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{group,start,address}',
  null::text,
  'an unconfirmed correction cannot expose a new participant address'
);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
do $$begin perform api.admin_startregie_confirm_start('duindorp-halloween-2026','23000000-0000-0000-0000-000000000001',2,pg_temp.event_settings_version());end $$;
select lives_ok(
  $$ select pg_temp.publish_current_schedule(
    array[(select correction_id from schedule_state)],
    'Gecorrigeerde groepsstart opnieuw gecontroleerd en bevestigd'
  ) $$,
  'the organizer can publish the correction without double-counting its superseded schedule'
);

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  api.group_snapshot('23000000-0000-0000-0000-000000000001') #>> '{group,start,address}',
  null::text,
  'the corrected start time still respects the address release boundary'
);

set local role postgres;
select is(
  (select state::text from app_private.group_schedule_revisions where id = (select first_id from schedule_state)),
  'superseded',
  'publishing a correction explicitly supersedes the prior revision'
);
select is(
  (select count(*)::integer from app_private.email_outbox where payload->>'groupId'='23000000-0000-0000-0000-000000000001' and message_type in ('group_schedule_published','group_schedule_corrected')),
  2,
  'a real time change keeps an auditable superseded event and one new notification'
);
select is(
  (select api.worker_group_schedule_mail_payload(id)->>'messageType' from app_private.email_outbox where payload->>'groupId'='23000000-0000-0000-0000-000000000001' and message_type in ('group_schedule_published','group_schedule_corrected') and status='pending' order by created_at desc limit 1),
  'group_schedule_published',
  'an unsent earlier time is not presented as a recipient-known correction'
);
select matches(
  (select payload ->> 'actionPath' from app_private.email_outbox where payload->>'groupId'='23000000-0000-0000-0000-000000000001' and message_type in ('group_schedule_published','group_schedule_corrected') and status='pending' order by created_at desc limit 1),
  '^/omgeving/',
  'schedule mail links to the private participant environment without future portal addresses'
);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  jsonb_typeof(api.admin_route_configuration_snapshot('duindorp-halloween-2026') -> 'finaleFlow'),
  'array',
  'the planning board can aggregate finale arrivals after schedule revisions exist'
);

select * from finish();
rollback;
