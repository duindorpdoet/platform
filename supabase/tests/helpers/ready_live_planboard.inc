-- Fixture setup for tests that need a complete event before checking mutations.
-- The dedicated bounded-initialization regression keeps raw snapshot calls.
create function pg_temp.ready_live_planboard(_event_slug text) returns jsonb
language plpgsql as $$
declare result jsonb; attempt integer;
begin
 for attempt in 1..100 loop
  result:=api.admin_live_planboard_snapshot(_event_slug);
  if coalesce((result->>'initializationPending')::integer,0)=0 then return result; end if;
 end loop;
 raise exception 'FIXTURE_LIVE_PLANBOARD_INITIALIZATION_DID_NOT_COMPLETE';
end $$;
