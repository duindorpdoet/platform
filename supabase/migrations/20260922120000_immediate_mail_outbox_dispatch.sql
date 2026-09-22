-- Wake the durable mail outbox immediately after a committed business transaction.
-- The scheduled job configured by configure_mail_worker remains the retry fallback.
create or replace function app_private.kick_mail_worker_after_outbox_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform app_private.dispatch_mail_worker();
  exception
    when others then
      -- A wake-up is deliberately best effort: losing it must never lose business data.
      null;
  end;
  return null;
end;
$$;

drop trigger if exists email_outbox_immediate_dispatch on app_private.email_outbox;
create trigger email_outbox_immediate_dispatch
after insert on app_private.email_outbox
for each statement
execute function app_private.kick_mail_worker_after_outbox_insert();

create or replace function api.dispatch_mail_worker_probe()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
begin
  return app_private.dispatch_mail_worker();
end;
$$;

create or replace function api.mail_worker_probe_result(_request_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare response record;
begin
  select id, status_code, timed_out, error_msg
  into response
  from net._http_response
  where id = _request_id;

  if response.id is null then
    return jsonb_build_object('found', false, 'statusCode', null, 'timedOut', false, 'error', null);
  end if;

  return jsonb_build_object(
    'found', true,
    'statusCode', response.status_code,
    'timedOut', coalesce(response.timed_out, false),
    'error', response.error_msg
  );
end;
$$;

revoke all on function app_private.kick_mail_worker_after_outbox_insert() from public, anon, authenticated;
revoke all on function api.dispatch_mail_worker_probe() from public, anon, authenticated;
revoke all on function api.mail_worker_probe_result(bigint) from public, anon, authenticated;
grant execute on function api.dispatch_mail_worker_probe() to service_role;
grant execute on function api.mail_worker_probe_result(bigint) to service_role;

notify pgrst, 'reload schema';
