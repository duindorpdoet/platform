-- Preserve all old immutable appointments and append a synthetic future one.
-- The API still uses real server time, including its private-address boundary.
insert into app_private.group_start_publications(event_id,group_id,source_key,revision,starts_at,published_at,point_snapshot,slot_snapshot)
select p.event_id,p.group_id,'fixture-future-appointment:'||p.id,p.revision,clock_timestamp()+interval '2 hours',
 clock_timestamp(),p.point_snapshot,p.slot_snapshot||jsonb_build_object('starts_at',clock_timestamp()+interval '2 hours')
from app_private.group_start_publications p join app_private.events e on e.id=p.event_id
where e.slug='duindorp-halloween-2026' and p.source_key like 'legacy:%'
on conflict(group_id,source_key) do nothing;
