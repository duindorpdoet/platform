-- Project at read time, including messages queued before this release.
-- This does not change mail-worker leases, retry handling or provider paths.
create or replace function api.worker_group_schedule_mail_payload(_outbox_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare message app_private.email_outbox; publication app_private.group_start_publications; projection jsonb;
begin
  select * into message from app_private.email_outbox where id=_outbox_id
    and message_type in ('group_schedule_published','group_schedule_corrected');
  if message.id is null then return null; end if;
  select * into publication from app_private.group_start_publications
    where group_id=(message.payload->>'groupId')::uuid order by publication_order desc limit 1;
  if publication.id is null or publication.revision is distinct from (message.payload->>'revision')::integer then return null; end if;
  projection:=app_private.published_start_projection(publication.group_id);
  return (message.payload-'startPoint'-'startAddress'-'coordinate'-'linkedPortalId')||jsonb_build_object(
    'startsAt',projection->'startsAt','addressReleaseAt',projection->'addressReleaseAt',
    'startPoint',case when (projection->>'addressReleased')::boolean then projection->'name' else '"Startlocatie volgt"'::jsonb end,
    'startAddress',projection->'address','addressReleased',projection->'addressReleased');
end;
$$;
revoke all on function api.worker_group_schedule_mail_payload(uuid) from public,anon,authenticated;
grant execute on function api.worker_group_schedule_mail_payload(uuid) to service_role;
