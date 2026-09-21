-- Brand/event bootstrap contains no fictitious participants or live routes.
insert into app_private.events(slug, title, local_date, timezone, phase, price_cents, settings)
values (
  'duindorp-halloween-2026',
  'De Duindorpse Poorten van Halloween',
  date '2026-10-31',
  'Europe/Amsterdam',
  'draft',
  200,
  jsonb_build_object(
    'registrationPublished', false,
    'routePlanPublished', false,
    'adultSupervisionRequired', true,
    'paymentMode', 'tikkie_manual',
    'maxChildren', 300,
    'operationalDataRetentionDays', 30,
    'offlineSnapshotTtlMinutes', 30
  )
)
on conflict (slug) do nothing;

with selected_event as (
  select id from app_private.events where slug = 'duindorp-halloween-2026'
), seed(slug, name, story, artwork_path, sort_order) as (
  values
    ('heksenrijk', 'Heksenrijk', 'Magie en spreuken achter paars verlichte poorten.', '/images/world-0.webp', 1),
    ('dodenrijk', 'Dodenrijk', 'Zielen en schaduwen, met duidelijke spanningswaarschuwingen.', '/images/world-1.webp', 2),
    ('circuswereld', 'Circuswereld', 'Illusie en chaos in een vergeten voorstelling.', '/images/world-2.webp', 3),
    ('besmette-zone', 'Besmette zone', 'Gevaar en mutatie in een groen verlicht experiment.', '/images/world-3.webp', 4),
    ('geestenwereld', 'Geestenwereld', 'Mist en verloren zielen die de weg naar huis zoeken.', '/images/world-4.webp', 5),
    ('vampierrijk', 'Vampierrijk', 'Een oud verhaal dat pas na zonsondergang begint.', '/images/world-5.webp', 6)
)
insert into app_private.worlds(event_id, slug, name, story, artwork_path, sort_order)
select selected_event.id, seed.slug, seed.name, seed.story, seed.artwork_path, seed.sort_order
from selected_event cross join seed
on conflict (event_id, slug) do update
set name = excluded.name, story = excluded.story, artwork_path = excluded.artwork_path, sort_order = excluded.sort_order;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values
  ('portal-application-assets', 'portal-application-assets', false, 8388608, array['image/jpeg', 'image/png', 'image/webp']),
  ('portal-qr-documents', 'portal-qr-documents', false, 10485760, array['application/pdf', 'image/png']),
  ('private-exports', 'private-exports', false, 20971520, array['text/csv', 'application/zip', 'application/pdf'])
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create or replace function app_private.can_access_application_asset(_object_name text, _actor uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select _actor is not null
    and split_part(_object_name, '/', 1) = _actor::text
    and exists (
      select 1 from app_private.portal_applications application
      where application.applicant_user_id = _actor
        and application.id::text = split_part(_object_name, '/', 2)
    )
$$;

create or replace function app_private.can_access_portal_document(_object_name text, _actor uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select _actor is not null and exists (
    select 1
    from app_private.portals portal
    where portal.id::text = split_part(_object_name, '/', 1)
      and (
        exists (select 1 from app_private.portal_owners owner where owner.portal_id = portal.id and owner.user_id = _actor and owner.revoked_at is null)
        or app_private.has_capability(portal.event_id, 'portals_manage', _actor)
      )
  )
$$;

create policy "application owners upload private images"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'portal-application-assets'
  and app_private.can_access_application_asset(name, (select auth.uid()))
  and lower(storage.extension(name)) in ('jpg', 'jpeg', 'png', 'webp')
);

create policy "application owners read private images"
on storage.objects for select to authenticated
using (bucket_id = 'portal-application-assets' and app_private.can_access_application_asset(name, (select auth.uid())));

create policy "application owners update private images"
on storage.objects for update to authenticated
using (bucket_id = 'portal-application-assets' and app_private.can_access_application_asset(name, (select auth.uid())))
with check (bucket_id = 'portal-application-assets' and app_private.can_access_application_asset(name, (select auth.uid())));

create policy "application owners delete private images"
on storage.objects for delete to authenticated
using (bucket_id = 'portal-application-assets' and app_private.can_access_application_asset(name, (select auth.uid())));

create policy "portal owners read qr documents"
on storage.objects for select to authenticated
using (bucket_id = 'portal-qr-documents' and app_private.can_access_portal_document(name, (select auth.uid())));

create or replace function app_private.can_access_realtime_topic(_topic text, _actor uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select _actor is not null and (
    case
      when _topic like 'group:%' then exists (
        select 1
        from app_private.walking_groups walking_group
        where walking_group.id::text = split_part(_topic, ':', 2)
          and (
            app_private.is_current_leader(walking_group.id, _actor)
            or app_private.has_capability(walking_group.event_id, 'live_support', _actor)
            or exists (
              select 1
              from app_private.household_members member
              join app_private.registrations registration on registration.household_id = member.household_id
              join app_private.group_registrations assignment on assignment.registration_id = registration.id
              where member.user_id = _actor and member.revoked_at is null
                and assignment.group_id = walking_group.id and assignment.superseded_at is null
            )
          )
      )
      when _topic like 'portal:%' then exists (
        select 1 from app_private.portals portal
        where portal.id::text = split_part(_topic, ':', 2)
          and (
            exists (select 1 from app_private.portal_owners owner where owner.portal_id = portal.id and owner.user_id = _actor and owner.revoked_at is null)
            or app_private.has_capability(portal.event_id, 'portals_manage', _actor)
          )
      )
      else false
    end
  )
$$;

grant usage on schema app_private to authenticated;
grant execute on function app_private.can_access_application_asset(text, uuid) to authenticated;
grant execute on function app_private.can_access_portal_document(text, uuid) to authenticated;
grant execute on function app_private.can_access_realtime_topic(text, uuid) to authenticated;

create policy "authorized clients receive scoped broadcasts"
on realtime.messages for select to authenticated
using (
  realtime.messages.extension = 'broadcast'
  and app_private.can_access_realtime_topic((select realtime.topic()), (select auth.uid()))
);

create or replace function app_private.notify_group_run_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform realtime.send(
    jsonb_build_object('resource', 'group_run', 'id', new.id, 'version', new.version),
    'snapshot_changed',
    'group:' || new.group_id::text,
    true
  );
  return new;
end;
$$;

create trigger group_run_broadcast_after_change
after insert or update on app_private.group_runs
for each row execute function app_private.notify_group_run_change();

revoke execute on function app_private.can_access_application_asset(text, uuid) from public, anon;
revoke execute on function app_private.can_access_portal_document(text, uuid) from public, anon;
revoke execute on function app_private.can_access_realtime_topic(text, uuid) from public, anon;
revoke execute on function app_private.notify_group_run_change() from public, anon, authenticated;
