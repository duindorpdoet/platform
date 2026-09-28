-- Forward-only: own-room moderation, shared live chat and cockpit updates.
begin;
alter table app_private.portal_owners add column chat_moderator boolean not null default false;

create function app_private.poortkamer_chat_moderator(_channel uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce(auth.uid() is not null and (
   app_private.has_capability(c.event_id,'event_admin') or app_private.has_capability(c.event_id,'portals_manage')
   or app_private.has_capability(c.event_id,'live_support')
   or (c.kind='team' and exists(select 1 from app_private.portal_owners o where o.portal_id=c.portal_id
     and o.user_id=auth.uid() and o.revoked_at is null and o.suspended_at is null
     and (o.role='owner' or o.chat_moderator)))
 ),false) from app_private.portal_room_channels c where c.id=_channel
$$;
revoke all on function app_private.poortkamer_chat_moderator(uuid) from public,anon,authenticated;


create or replace function api.portal_chat_snapshot(_channel_id uuid,_before bigint default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c app_private.portal_room_channels;
begin
 c:=app_private.poortkamer_channel_access(_channel_id);
 return jsonb_build_object('channelId',c.id,'canModerate',app_private.poortkamer_chat_moderator(c.id),
 'canPin',app_private.poortkamer_chat_moderator(c.id) or (c.kind='team' and app_private.poortkamer_role(c.portal_id)='coadmin'),
 'canPost',case when c.kind='announcements' then app_private.poortkamer_chat_moderator(c.id) when c.kind='community' then not exists(select 1 from app_private.portal_community_mutes where event_id=c.event_id and user_id=auth.uid() and until_at>now()) else true end,
 'retainedUntil',(select local_date+interval '1 month' from app_private.events where id=c.event_id),
 'messages',coalesce((select jsonb_agg(item order by mid) from (
  select m.id mid,jsonb_build_object('id',m.id,'body',case when m.hidden_at is null then m.body else 'Dit bericht is verborgen door een moderator.' end,
  'system',m.system,'urgent',m.urgent,'pinned',m.pinned,'hidden',m.hidden_at is not null,'createdAt',m.created_at,
  'sender',case when m.system then 'De Poortkamer' when c.kind='announcements' then 'De organisatie'
    when c.kind='team' then coalesce(nullif(concat_ws(' ',o.first_name,o.last_name),''),pr.display_name,'Poortwachter')
    else coalesce(o.first_name,split_part(pr.display_name,' ',1),'Poortwachter') end,
  'role',case when c.kind='team' then coalesce(o.role,'admin') else null end,
  'portalCode',case when c.kind='community' then p.system_code else null end,'portalName',case when c.kind='community' then p.name else null end,
  'mentionUserId',case when c.kind='community' and m.hidden_at is null and o.user_id is not null and p.approval_status='approved' then m.actor_id else null end,
  'own',m.actor_id=auth.uid(),'reactions',coalesce((select jsonb_agg(jsonb_build_object('emoji',r.reaction,'count',r.n,'own',r.own)) from
    (select reaction,count(*) n,bool_or(user_id=auth.uid()) own from app_private.portal_room_reactions where message_id=m.id group by reaction) r),'[]'::jsonb)) item
  from app_private.portal_room_messages m
  left join app_private.portals p on p.id=m.sender_portal_id
  left join app_private.portal_owners o on o.portal_id=coalesce(c.portal_id,m.sender_portal_id) and o.user_id=m.actor_id and o.revoked_at is null
  left join app_private.profiles pr on pr.user_id=m.actor_id
  where m.channel_id=c.id and (_before is null or m.id<_before) order by m.id desc limit 60
 ) bounded),'[]'::jsonb),
 'pins',coalesce((select jsonb_agg(jsonb_build_object('id',id,'body',body)) from(select id,body from app_private.portal_room_messages where channel_id=c.id and pinned and hidden_at is null order by id desc limit 5) pins),'[]'::jsonb));
end $$;

create or replace function api.portal_chat_action(_channel_id uuid,_operation text,_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c app_private.portal_room_channels; mid bigint:=(_payload->>'messageId')::bigint; m app_private.portal_room_messages; allowed boolean;
begin
 c:=app_private.poortkamer_channel_access(_channel_id);
 if _operation in ('read','mute') then
  if _operation='read' then
   insert into app_private.portal_room_reads(channel_id,user_id,last_read_id) values(c.id,auth.uid(),least(coalesce(mid,0),coalesce((select max(id) from app_private.portal_room_messages where channel_id=c.id),0)))
   on conflict(channel_id,user_id) do update set last_read_id=greatest(portal_room_reads.last_read_id,excluded.last_read_id);
  else insert into app_private.portal_room_reads(channel_id,user_id,muted) values(c.id,auth.uid(),(_payload->>'muted')::boolean)
   on conflict(channel_id,user_id) do update set muted=excluded.muted;
  end if;
 else
  select * into m from app_private.portal_room_messages where id=mid and channel_id=c.id for update;
  if m.id is null then raise exception 'MESSAGE_NOT_FOUND'; end if;
  perform app_private.poortkamer_budget('chat_action',30);
  if _operation='react' then
   if m.hidden_at is not null or c.kind='announcements' then raise exception 'REACTION_UNAVAILABLE'; end if;
   if (_payload->>'active')::boolean then insert into app_private.portal_room_reactions values(mid,auth.uid(),_payload->>'emoji') on conflict do nothing;
   else delete from app_private.portal_room_reactions where message_id=mid and user_id=auth.uid() and reaction=_payload->>'emoji'; end if;
  elsif _operation='report' then
   insert into app_private.portal_room_reports(message_id,reported_by,reason) values(mid,auth.uid(),trim(_payload->>'reason')) on conflict(message_id,reported_by) do nothing;
  elsif _operation in ('hide','pin','mute_author','resolve') then
   allowed:=app_private.has_capability(c.event_id,'event_admin') or app_private.has_capability(c.event_id,'portals_manage') or app_private.has_capability(c.event_id,'live_support');
   if _operation in ('pin','hide','resolve') and c.kind='team' then allowed:=allowed or app_private.poortkamer_chat_moderator(c.id); end if;
   if _operation='pin' and c.kind='team' then allowed:=allowed or app_private.poortkamer_role(c.portal_id)='coadmin'; end if;
   if not allowed then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   if _operation='pin' then update app_private.portal_room_messages set pinned=(_payload->>'pinned')::boolean where id=mid;
   elsif _operation='hide' then update app_private.portal_room_messages set hidden_at=coalesce(hidden_at,now()) where id=mid;
   elsif _operation='mute_author' then
    if c.kind<>'community' or m.actor_id is null or char_length(trim(_payload->>'reason')) not between 5 and 500 then raise exception 'INVALID_MODERATION'; end if;
    insert into app_private.portal_community_mutes(event_id,user_id,until_at,reason) values(c.event_id,m.actor_id,now()+interval '24 hours',trim(_payload->>'reason'))
    on conflict(event_id,user_id) do update set until_at=excluded.until_at,reason=excluded.reason;
   end if;
   update app_private.portal_room_reports set resolved_at=now() where message_id=mid and _operation in ('hide','resolve','mute_author');
   insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(c.event_id,auth.uid(),'portal.chat.'||_operation,'portal_channel',c.id,jsonb_build_object('messageId',mid));
  else raise exception 'INVALID_OPERATION'; end if;
  perform realtime.send(jsonb_build_object('id',c.id,'messageId',mid),'snapshot_changed',case when c.kind='team' then app_private.poortkamer_portal_topic(c.portal_id) else app_private.poortkamer_community_topic(c.event_id) end,true);
  perform realtime.send(jsonb_build_object('id',c.id,'messageId',mid),'snapshot_changed','admin-event:'||c.event_id,true);
 end if;
 return jsonb_build_object('ok',true);
end $$;

create or replace function app_private.poortkamer_message_signal() returns trigger language plpgsql security definer set search_path='' as $$
declare c app_private.portal_room_channels;
begin
 select * into c from app_private.portal_room_channels where id=new.channel_id;
 perform realtime.send(jsonb_build_object('id',c.id,'messageId',new.id),'snapshot_changed',case when c.kind='team' then app_private.poortkamer_portal_topic(c.portal_id) else app_private.poortkamer_community_topic(c.event_id) end,true);
 perform realtime.send(jsonb_build_object('id',c.id,'messageId',new.id),'snapshot_changed','admin-event:'||c.event_id,true);
 return new;
end $$;

create or replace function api.portal_room_snapshot(_event_slug text,_portal_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb; pid uuid;
begin
  base:=api.portal_room_snapshot_v1(_event_slug,_portal_id);
  if base is null then return null; end if;
  pid:=(base#>>'{portal,id}')::uuid;
  -- Hide retired V1 navigation entries; retained messages and audit history are untouched.
  base:=jsonb_set(base,'{channels}',coalesce((select jsonb_agg(c) from jsonb_array_elements(base->'channels') c
    where c->>'name' not in ('Snoep & voorraad','Algemeen')),'[]'::jsonb));
  base:=jsonb_set(base,'{team}',coalesce((select jsonb_agg(jsonb_build_object(
    'userId',o.user_id,'name',coalesce(nullif(concat_ws(' ',o.first_name,o.last_name),''),pr.display_name,'Poortwachter'),
    'role',o.role,'task',o.task_label,'lastSeenAt',o.last_seen_at,'accessLevel',o.access_level,'suspendedAt',o.suspended_at,'chatModerator',o.chat_moderator)
    order by (o.role='owner') desc,o.accepted_at)
    from app_private.portal_owners o left join app_private.profiles pr on pr.user_id=o.user_id
    where o.portal_id=pid and o.revoked_at is null),'[]'::jsonb));
  return base||jsonb_build_object('v2',app_private.poortkamer_v2_snapshot(pid),
    'announcements',coalesce((select jsonb_agg(item order by mid desc) from (
      select m.id mid,jsonb_build_object('id',m.id,'body',m.body,'urgent',m.urgent,'createdAt',m.created_at) item
      from app_private.portal_room_messages m join app_private.portal_room_channels c on c.id=m.channel_id
      where c.event_id=(base->>'eventId')::uuid and c.kind='announcements' and m.hidden_at is null
      order by m.id desc limit 5) updates),'[]'::jsonb));
end $$;


alter function api.portal_team_command(uuid,text,jsonb,uuid) rename to portal_team_command_before_design;
create function api.portal_team_command(_portal_id uuid,_operation text,_payload jsonb,_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.portals; member app_private.portal_owners; result jsonb;
 receipt app_private.command_receipts; request_hash text; enabled boolean;
begin
 if _operation<>'chat_moderator' then return api.portal_team_command_before_design(_portal_id,_operation,_payload,_key); end if;
 select * into p from app_private.portals where id=_portal_id for update;
 perform app_private.poortkamer_require(_portal_id,'team');
 request_hash:=encode(extensions.digest(convert_to(jsonb_build_array(_portal_id,_operation,_payload)::text,'UTF8'),'sha256'),'hex');
 select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.moderator' and idempotency_key=_key::text;
 if found then
   if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
   return receipt.safe_result;
 end if;
 if jsonb_typeof(_payload->'enabled') is distinct from 'boolean' then raise exception 'INVALID_MODERATION'; end if;
 enabled:=(_payload->>'enabled')::boolean;
 select * into member from app_private.portal_owners where portal_id=p.id and user_id=(_payload->>'userId')::uuid and revoked_at is null and suspended_at is null for update;
 if member.user_id is null then raise exception 'MEMBER_NOT_FOUND'; end if;
 if member.role='owner' then raise exception 'OWNER_IS_MODERATOR'; end if;
 perform app_private.poortkamer_budget('team',10);
 update app_private.portal_owners set chat_moderator=enabled where portal_id=p.id and user_id=member.user_id;
 result:=jsonb_build_object('userId',member.user_id,'chatModerator',enabled);
 perform app_private.poortkamer_signal(p.id,'portal.team.chat_moderator',result,'De chatrechten van een teamlid zijn bijgewerkt.');
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
 values(auth.uid(),'portal.moderator',_key::text,request_hash,result,now()+interval '30 days');
 return result;
end $$;
revoke all on function api.portal_team_command_before_design(uuid,text,jsonb,uuid) from public,anon,authenticated;
revoke all on function api.portal_team_command(uuid,text,jsonb,uuid),api.portal_chat_snapshot(uuid,bigint),api.portal_chat_action(uuid,text,jsonb),api.portal_room_snapshot(text,uuid) from public,anon;
grant execute on function api.portal_team_command(uuid,text,jsonb,uuid),api.portal_chat_snapshot(uuid,bigint),api.portal_chat_action(uuid,text,jsonb),api.portal_room_snapshot(text,uuid) to authenticated;


create or replace function api.admin_portal_room_snapshot(_event_slug text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb; eid uuid;
begin
  base:=api.admin_portal_room_snapshot_v1(_event_slug);
  select id into eid from app_private.events where slug=_event_slug;
  base:=jsonb_set(base,'{channels}',coalesce((select jsonb_agg(c) from jsonb_array_elements(base->'channels') c where c->>'name' not in ('Snoep & voorraad','Algemeen')),'[]'::jsonb));
  return base||jsonb_build_object('userId',auth.uid(),'eventId',eid,'communityTopic',app_private.poortkamer_community_topic(eid),

    'incidents',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'portalId',i.portal_id,'portalCode',p.system_code,'portalName',p.name,'category',i.category,'urgency',i.urgency,'status',i.status,'description',i.description,'callbackRequested',i.callback_requested,'assignedTo',i.assigned_to,'createdAt',i.created_at) order by (i.urgency='high') desc,i.created_at desc) from app_private.portal_incidents i join app_private.portals p on p.id=i.portal_id where i.event_id=eid and i.status not in ('resolved','closed')),'[]'::jsonb),
    'presentations',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'portalId',v.portal_id,'portalCode',p.system_code,'version',v.version,'status',v.status,'publicName',v.public_name,'submittedAt',v.submitted_at) order by v.submitted_at) from app_private.portal_presentations v join app_private.portals p on p.id=v.portal_id where p.event_id=eid and v.status in ('submitted','changes_requested')),'[]'::jsonb));
end $$;
create or replace function api.poortenboek_admin(_actor uuid,_event_slug text,_action text,_payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; eventid uuid; teamid uuid;
begin
  result:=api.poortenboek_admin_v1(_actor,_event_slug,_action,_payload);
  if _action='reset' then
    select id into eventid from app_private.events where slug=_event_slug;
    teamid:=(_payload->>'teamId')::uuid;
    delete from app_private.poortenboek_banner_votes where event_id=eventid and team_id=teamid;
    insert into app_private.poortenboek_team_customizations(event_id,team_id,reset_count)
      values(eventid,teamid,1) on conflict(event_id,team_id) do update set banner=null,decided_at=null,reset_count=least(app_private.poortenboek_team_customizations.reset_count+1,1),updated_at=now();
  end if;
  select id into eventid from app_private.events where slug=_event_slug;
  result:=jsonb_set(result,'{elections}',coalesce((select jsonb_agg(e||jsonb_build_object('teamLabel',coalesce(p.cluster_reference,
    (select min(reg.reference) from app_private.together_memberships m join app_private.registrations reg on reg.id=m.registration_id where m.party_id=p.id and m.left_at is null),'Reisgezelschap')))
    from jsonb_array_elements(result->'elections') e left join app_private.together_parties p on p.id=(e->>'teamId')::uuid and p.event_id=eventid),'[]'::jsonb));
  return result;
end $$;
commit;
