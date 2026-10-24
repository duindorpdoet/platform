begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select ok(not has_function_privilege('authenticated','app_private.poortkamer_channels(uuid,uuid)','execute'),'channel maintenance stays private');
select app_private.poortkamer_channels((select id from app_private.events where slug='duindorp-halloween-2026'),'12000000-0000-0000-0000-000000000001');
create temp table channel_before as select id,ctid::text physical_version,to_jsonb(c) original from app_private.portal_room_channels c;
select app_private.poortkamer_channels((select id from app_private.events where slug='duindorp-halloween-2026'),'12000000-0000-0000-0000-000000000001') from generate_series(1,3);
select is((select count(*)::integer from channel_before b join app_private.portal_room_channels c using(id) where c.ctid::text<>b.physical_version),0,'repeated refresh does not even rewrite unchanged channel rows');
select is((select count(*)::integer from channel_before b join app_private.portal_room_channels c using(id) where to_jsonb(c)<>b.original),0,'repeat preserves IDs, archive timestamps and complete channel contents');
select app_private.poortkamer_channels((select id from app_private.events where slug='duindorp-halloween-2026'),'12000000-0000-0000-0000-000000000002');
select is((select count(*)::integer from channel_before b join app_private.portal_room_channels c using(id) where c.ctid::text<>b.physical_version),0,'another house does not update the shared event channels');
select is((select count(*)::integer from app_private.portal_room_channels where portal_id='12000000-0000-0000-0000-000000000002' and kind='team' and archived_at is null),4,'a new house still lazily receives its four private channels');
update app_private.portal_room_channels set archived_at=now() where id=(select id from app_private.portal_room_channels where portal_id='12000000-0000-0000-0000-000000000001' and name='Achter de Poort');
select app_private.poortkamer_channels((select id from app_private.events where slug='duindorp-halloween-2026'),'12000000-0000-0000-0000-000000000001');
select ok((select archived_at is null from app_private.portal_room_channels where portal_id='12000000-0000-0000-0000-000000000001' and name='Achter de Poort'),'an actually archived required team channel is reopened');
select is((select count(*)::integer from app_private.portal_room_channels where portal_id='12000000-0000-0000-0000-000000000001' and name='Achter de Poort'),1,'reopening does not replace the stable channel');
insert into app_private.events(id,slug,title,local_date,phase,price_cents) values('85000000-0000-0000-0000-000000000001','isolated-channel-refresh','Fictieve kanaalcontrole','2026-10-31','draft',0);
insert into app_private.portal_room_channels(id,event_id,kind,name) values
 ('85000000-0000-0000-0000-000000000002','85000000-0000-0000-0000-000000000001','announcements','De Omroeper'),
 ('85000000-0000-0000-0000-000000000003','85000000-0000-0000-0000-000000000001','community','Hulp & materialen'),
 ('85000000-0000-0000-0000-000000000004','85000000-0000-0000-0000-000000000001','community','Snoep & voorraad');
select app_private.poortkamer_channels('85000000-0000-0000-0000-000000000001');
select is((select name from app_private.portal_room_channels where id='85000000-0000-0000-0000-000000000002'),'Mededelingen','legacy announcement keeps its ID when renamed');
select is((select name from app_private.portal_room_channels where id='85000000-0000-0000-0000-000000000003'),'Hulp gevraagd','legacy help room keeps its ID when renamed');
select ok((select archived_at is not null from app_private.portal_room_channels where id='85000000-0000-0000-0000-000000000004'),'legacy stock room is archived without deletion');
select is((select count(*)::integer from app_private.portal_room_channels where event_id='85000000-0000-0000-0000-000000000001' and archived_at is null),3,'cold initialization retains exactly three active shared channels');
select * from finish();
rollback;
