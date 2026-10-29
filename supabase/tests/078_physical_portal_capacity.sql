begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table capacity_test(pid uuid,g1 uuid,g2 uuid,g3 uuid);
insert into capacity_test values('12000000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000002','23000000-0000-0000-0000-000000000003');
update app_private.portal_windows set opens_at='2026-10-31T16:00:00Z',closes_at='2026-10-31T21:00:00Z',visit_minutes=6,buffer_minutes=2,max_concurrent_groups=1,max_children_per_visit=15 where portal_id=(select pid from capacity_test);
insert into app_private.portal_reservations(event_id,portal_id,group_id,kind,status,reserved_from,reserved_until,child_count)
select (select event_id from app_private.portals where id=pid),pid,g1,'ordinary','completed','2026-10-31T17:00:00Z','2026-10-31T17:08:00Z',15 from capacity_test;
select is(app_private.portal_interval_available(pid,g2,'2026-10-31T17:04:00Z','2026-10-31T17:12:00Z',15,'2026-10-31T17:01:00Z'),false,'completed scan still physically occupies its 6+2 reception interval') from capacity_test;
select is(app_private.portal_interval_available(pid,g2,'2026-10-31T17:10:00Z','2026-10-31T17:18:00Z',15,'2026-10-31T17:01:00Z'),true,'freed later gap is available automatically to the common dispatcher check') from capacity_test;
update app_private.portal_windows set max_concurrent_groups=2 where portal_id=(select pid from capacity_test);
select is(app_private.portal_interval_available(pid,g2,'2026-10-31T17:05:00Z','2026-10-31T17:13:00Z',15,'2026-10-31T17:01:00Z'),true,'two allowed groups can overlap after the minimum arrival interval: per-visit children are not a combined cap') from capacity_test;
select is(app_private.portal_interval_available(pid,g2,'2026-10-31T17:05:00Z','2026-10-31T17:13:00Z',16,'2026-10-31T17:01:00Z'),false,'physical per-visit child cap remains binding') from capacity_test;
select is(app_private.portal_interval_available(pid,g2,'2026-10-31T20:58:00Z','2026-10-31T21:06:00Z',1,'2026-10-31T17:01:00Z'),false,'whole reception interval must fit opening window') from capacity_test;
select is(app_private.portal_interval_available(pid,g2,'2026-10-31T17:08:00Z','2026-10-31T17:16:00Z',15,'2026-10-31T17:09:00Z'),true,'half-open intervals release capacity at the precise end') from capacity_test;
update app_private.portal_windows set max_children_total=20 where portal_id=(select pid from capacity_test);
select is(app_private.portal_interval_available(pid,g2,'2026-10-31T17:10:00Z','2026-10-31T17:18:00Z',15,'2026-10-31T17:01:00Z'),false,'a separately configured total child quota remains distinct from simultaneous per-visit limits') from capacity_test;
select * from finish();
rollback;
