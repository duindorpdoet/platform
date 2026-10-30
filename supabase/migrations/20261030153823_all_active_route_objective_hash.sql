-- Invalidate proposals computed before the all-active physical coverage goal.
-- Keep the authoritative v3 source, hard policy, settings and accepted run
-- snapshots unchanged. CREATE OR REPLACE retains the existing owner and ACL.
create or replace function app_private.joint_route_source_hash(_event uuid)
returns text language sql stable security definer set search_path='' as $$
 select encode(extensions.digest(jsonb_build_object(
  'policyVersion',3,'routeObjective','all-active-coverage-v1',
  'source',app_private.joint_route_source_hash_before_v3(_event)
 )::text,'sha256'),'hex')
$$;
