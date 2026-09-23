-- Deployment owns the fixed public-form destination; visitors cannot choose it.
create or replace function api.configure_notification_recipient(_event_slug text, _email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare event_record app_private.events; recipient text := lower(trim(_email));
begin
  if recipient is null or char_length(recipient) > 320
     or recipient !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
    raise exception 'INVALID_NOTIFICATION_RECIPIENT' using errcode = '22023';
  end if;
  update app_private.events
  set settings = settings || jsonb_build_object('supportEmail', recipient),
      settings_version = settings_version + 1
  where slug = _event_slug returning * into event_record;
  if event_record.id is null then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  insert into app_private.audit_events(event_id, action, resource_type, resource_id, minimal_change)
  values (event_record.id, 'release.notification_recipient_configured', 'event', event_record.id, '{}'::jsonb);
  return jsonb_build_object('configured', true);
end;
$$;
revoke all on function api.configure_notification_recipient(text, text) from public, anon, authenticated;
grant execute on function api.configure_notification_recipient(text, text) to service_role;
notify pgrst, 'reload schema';
