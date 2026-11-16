-- Rollback-only test data. Move this fixture calendar two years ahead of the
-- current year so real server time can still exercise pre-release boundaries.
-- No production clock override, weakened time predicate, or immutable-row edit.
create function pg_temp.fixture_time(_instant timestamptz) returns timestamptz
language sql stable set search_path='' as $$
 select _instant+make_interval(years=>extract(year from current_date)::integer+2-2026)
$$;
grant execute on function pg_temp.fixture_time(timestamptz) to authenticated;
update app_private.events set local_date=(pg_temp.fixture_time(local_date::timestamp at time zone timezone) at time zone timezone)::date
where slug='duindorp-halloween-2026';
update app_private.portal_windows w set opens_at=pg_temp.fixture_time(w.opens_at),closes_at=pg_temp.fixture_time(w.closes_at)
from app_private.portals p join app_private.events e on e.id=p.event_id
where w.portal_id=p.id and e.slug='duindorp-halloween-2026';
update app_private.start_slots set starts_at=pg_temp.fixture_time(starts_at)
where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
update app_private.registrations set preferred_start_at=pg_temp.fixture_time(preferred_start_at),
 desired_end_at=pg_temp.fixture_time(desired_end_at),requested_ordinary_stop_at=pg_temp.fixture_time(requested_ordinary_stop_at)
where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
update app_private.portal_credentials c set valid_until=pg_temp.fixture_time(timestamptz '2026-11-01 00:00:00+01')
from app_private.portals p join app_private.events e on e.id=p.event_id
where c.portal_id=p.id and e.slug='duindorp-halloween-2026';
insert into app_private.group_start_publications(event_id,group_id,source_key,revision,starts_at,published_at,point_snapshot,slot_snapshot)
select p.event_id,p.group_id,'fixture-future-calendar:'||p.id,p.revision,pg_temp.fixture_time(p.starts_at),
 clock_timestamp(),p.point_snapshot,p.slot_snapshot||jsonb_build_object('starts_at',pg_temp.fixture_time(p.starts_at))
from app_private.group_start_publications p join app_private.events e on e.id=p.event_id
where e.slug='duindorp-halloween-2026' and p.source_key like 'legacy:%'
on conflict(group_id,source_key) do nothing;
