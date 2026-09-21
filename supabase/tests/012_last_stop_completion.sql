begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

create temporary table completion_values(
  children uuid[],
  run_id uuid,
  final_stop_id uuid,
  final_run_version integer,
  final_result jsonb
) on commit drop;
insert into completion_values(children)
select array_agg(registration_child.id order by registration_child.id)
from app_private.registration_children registration_child
join app_private.registrations registration on registration.id = registration_child.registration_id
where registration.reference = 'FIXTURE-1';
grant select, update on completion_values to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $test$
    do $do$
    declare
      snapshot jsonb;
      active_stop_id uuid;
      active_run_version integer;
      run_identifier uuid;
      completion jsonb;
    begin
      update completion_values
      set run_id = (
        api.run_start(
          '23000000-0000-0000-0000-000000000001',
          (select children from completion_values),
          1,
          'last-stop-start',
          'last-stop-start-hash'
        )->>'runId'
      )::uuid;
      select run_id into run_identifier from completion_values;

      for stop_number in 1..6 loop
        snapshot := api.group_snapshot('23000000-0000-0000-0000-000000000001');
        active_stop_id := (snapshot #>> '{run,currentStop,id}')::uuid;
        active_run_version := (snapshot #>> '{run,version}')::integer;
        perform api.run_bulk_skip_pending(
          run_identifier,
          active_stop_id,
          active_run_version,
          'Alle aanwezigen slaan deze testpoort over',
          format('last-stop-bulk-%s', stop_number),
          format('last-stop-bulk-hash-%s', stop_number)
        );
        completion := api.run_complete_stop(
          run_identifier,
          active_stop_id,
          active_run_version,
          true,
          format('last-stop-complete-%s', stop_number),
          format('last-stop-complete-hash-%s', stop_number)
        );
        if stop_number = 6 then
          update completion_values
          set final_stop_id = active_stop_id,
              final_run_version = active_run_version,
              final_result = completion;
        end if;
      end loop;
    end
    $do$
  $test$,
  'leader advances through all six published stops using explicit all-skip confirmation'
);
select is((select final_result->>'status' from completion_values), 'completed', 'last stop completes the run');
select is((select final_result->>'hasNextStop' from completion_values), 'false', 'last stop reports no next destination');
select is(
  api.group_snapshot('23000000-0000-0000-0000-000000000001') #> '{run,currentStop}',
  'null'::jsonb,
  'completed snapshot exposes no current or recycled first stop'
);
select is(
  jsonb_array_length(api.group_snapshot('23000000-0000-0000-0000-000000000001') #> '{run,history}'),
  6,
  'completed snapshot retains all six historical stops'
);
select is(
  api.run_complete_stop(
    (select run_id from completion_values),
    (select final_stop_id from completion_values),
    (select final_run_version from completion_values),
    true,
    'last-stop-complete-6',
    'last-stop-complete-hash-6'
  ),
  (select final_result from completion_values),
  'retry of the final command returns the one stored completion result'
);

set local role postgres;
select is(
  (select status::text from app_private.group_runs where id = (select run_id from completion_values)),
  'completed',
  'persisted run status is completed'
);
select is(
  (select status::text from app_private.walking_groups where id = '23000000-0000-0000-0000-000000000001'),
  'completed',
  'persisted walking group status is completed'
);
select ok(
  (select count(*) = 6 from app_private.run_stops where run_id = (select run_id from completion_values) and state = 'completed')
  and not exists (select 1 from app_private.run_stops where run_id = (select run_id from completion_values) and state <> 'completed'),
  'all and only the six route stops are completed'
);
select ok(
  (select count(*) = 6 from app_private.group_seals where run_id = (select run_id from completion_values) and outcome = 'all_skipped'),
  'each explicitly skipped stop has its own truthful skip seal'
);

select * from finish();
rollback;
