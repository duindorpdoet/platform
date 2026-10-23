-- Isolated rollback fixtures for arrival/leadership tests. Existing appointments
-- stay immutable: append a synthetic already-startable appointment instead of
-- giving the application a clock override or weakening its time gate.
insert into app_private.group_start_publications(event_id,group_id,source_key,revision,starts_at,published_at,point_snapshot,slot_snapshot)
select p.event_id,p.group_id,'fixture-start-available:'||p.id,p.revision,clock_timestamp()-interval '1 minute',
  clock_timestamp(),p.point_snapshot,p.slot_snapshot||jsonb_build_object('starts_at',clock_timestamp()-interval '1 minute')
from app_private.group_start_publications p join app_private.walking_groups g on g.id=p.group_id
where g.event_id=(select id from app_private.events where slug='duindorp-halloween-2026')
  and p.source_key like 'legacy:%' on conflict(group_id,source_key) do nothing;
