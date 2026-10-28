-- PostgREST converts arguments as service_role before entering SECURITY DEFINER.
-- Keep the private enum behind a text-only boundary; do not widen schema grants.
create function api.worker_update_outbox_v2(
  _id uuid,
  _status text,
  _provider_id text default null,
  _error_code text default null,
  _next_attempt_at timestamptz default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if _status is null or _status not in ('accepted','delivered','deferred','failed','unknown','suppressed','validated') then
    raise exception using errcode = '22023', message = 'INVALID_OUTBOX_STATUS';
  end if;
  perform api.worker_update_outbox(
    _id, _status::app_private.outbox_status, _provider_id, _error_code, _next_attempt_at
  );
end;
$$;
revoke all on function api.worker_update_outbox_v2(uuid,text,text,text,timestamptz) from public, anon, authenticated;
grant execute on function api.worker_update_outbox_v2(uuid,text,text,text,timestamptz) to service_role;
notify pgrst, 'reload schema';
