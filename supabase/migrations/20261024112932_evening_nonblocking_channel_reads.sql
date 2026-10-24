-- Snapshot refreshes must not acquire the same event-wide channel row locks.
-- Preserve lazy creation and legacy names, updating only actual transitions.
set lock_timeout='5s';
create or replace function app_private.poortkamer_channels(_event uuid,_portal uuid default null)
returns void language plpgsql security definer set search_path='' as $$
begin
  update app_private.portal_room_channels c set name='Mededelingen'
  where c.event_id=_event and c.kind='announcements' and c.name='De Omroeper'
    and not exists(select 1 from app_private.portal_room_channels existing
      where existing.event_id=_event and existing.kind='announcements' and existing.name='Mededelingen');
  update app_private.portal_room_channels c set name='Hulp gevraagd'
  where c.event_id=_event and c.kind='community' and c.name='Hulp & materialen' and c.archived_at is null
    and not exists(select 1 from app_private.portal_room_channels existing
      where existing.event_id=_event and existing.kind='community' and existing.name='Hulp gevraagd');
  update app_private.portal_room_channels c set archived_at=now()
  where c.event_id=_event and c.kind='community' and c.archived_at is null
    and c.name in('Hulp & materialen','Snoep & voorraad','Voorbereiding','Decor & techniek','Decor en techniek','Tijdens de avond');
  update app_private.portal_room_channels c set archived_at=now()
  where c.event_id=_event and c.kind='announcements' and c.name='De Omroeper' and c.archived_at is null;

  insert into app_private.portal_room_channels(event_id,kind,name,archived_at)
  select _event,v.kind,v.name,null
  from(values('community','Algemeen'),('community','Hulp gevraagd'),('announcements','Mededelingen')) v(kind,name)
  where not exists(select 1 from app_private.portal_room_channels c
    where c.event_id=_event and c.portal_id is null and c.name=v.name)
  on conflict(event_id,portal_id,name) do nothing;
  update app_private.portal_room_channels c set archived_at=null
  where c.event_id=_event and c.portal_id is null and c.archived_at is not null
    and ((c.kind='community' and c.name in('Algemeen','Hulp gevraagd')) or (c.kind='announcements' and c.name='Mededelingen'));
  if _portal is not null then
    insert into app_private.portal_room_channels(event_id,portal_id,kind,name,archived_at)
    select _event,_portal,'team',v.name,null
    from(values('Achter de Poort'),('Voorbereiding'),('Decor en techniek'),('Tijdens de avond')) v(name)
    where not exists(select 1 from app_private.portal_room_channels c
      where c.event_id=_event and c.portal_id=_portal and c.name=v.name)
    on conflict(event_id,portal_id,name) do nothing;
    update app_private.portal_room_channels c set archived_at=null
    where c.event_id=_event and c.portal_id=_portal and c.kind='team' and c.archived_at is not null
      and c.name in('Achter de Poort','Voorbereiding','Decor en techniek','Tijdens de avond');
  end if;
end $$;
revoke all on function app_private.poortkamer_channels(uuid,uuid) from public,anon,authenticated;
