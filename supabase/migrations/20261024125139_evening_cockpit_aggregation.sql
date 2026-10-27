-- Build shared counts once per event, retaining the existing authorization and
-- JSON contracts. No business rows or cached participant data are changed.
set lock_timeout='5s';
create or replace function api.admin_evening_cockpit(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid();eid uuid;
begin
 select id into eid from app_private.events where slug=_event_slug;
 if eid is null or actor is null or not(app_private.has_capability(eid,'live_support',actor)
   or app_private.has_capability(eid,'groups_manage',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return (
 with scoped_groups as materialized(select * from app_private.walking_groups where event_id=eid),
 assignments as materialized(
   select a.group_id,a.registration_id,r.household_id from app_private.group_registrations a
   join scoped_groups g on g.id=a.group_id join app_private.registrations r on r.id=a.registration_id
   where a.superseded_at is null
 ), adults as (
   select a.group_id,jsonb_agg(distinct jsonb_build_object('userId',u.id,'email',u.email)) people
   from assignments a join app_private.household_members m on m.household_id=a.household_id and m.revoked_at is null
   join auth.users u on u.id=m.user_id group by a.group_id
 ), children as (
   select a.group_id,count(*) n from assignments a join app_private.registration_children c
   on c.registration_id=a.registration_id and c.participation_status='active' group by a.group_id
 ), leaders as (
   select distinct on(l.group_id) l.group_id,u.email from app_private.group_leaders l
   join scoped_groups g on g.id=l.group_id join auth.users u on u.id=l.user_id
   where l.active_from<=now() and(l.active_until is null or l.active_until>now()) order by l.group_id,l.active_from desc
 ), bookings as materialized(
   select b.portal_id,count(*) n,sum(b.child_count) children from app_private.portal_reservations b
   join app_private.portals p on p.id=b.portal_id where p.event_id=eid and b.status in('held','active') group by b.portal_id
 )
 select jsonb_build_object(
 'groups',coalesce((select jsonb_agg(jsonb_build_object(
   'groupId',g.id,'groupCode',g.system_code,'systemCode',g.system_code,'displayName',g.display_name,'groupVersion',g.version,
   'status',g.status,'runId',r.id,'runStatus',r.status,'runVersion',r.version,'currentStopId',r.current_stop_id,
   'currentPortal',p.name,'currentKind',s.stop_kind,'lastConfirmedAt',r.updated_at,
   'currentCoordinate',case when loc.latitude is null then null else jsonb_build_array(loc.longitude,loc.latitude) end,
   'leaderEmail',l.email,'responsibleAdults',coalesce(a.people,'[]'::jsonb),
   'elapsedSeconds',case when r.started_at is null then null else greatest(0,extract(epoch from(now()-r.started_at))::integer) end,
   'effectiveStopAt',schedule.effective_ordinary_stop_at,'expectedFinaleArrivalAt',coalesce(f.reserved_from,schedule.expected_finale_arrival_at),
   'childCount',coalesce(c.n,0)) order by g.code)
   from scoped_groups g left join app_private.group_runs r on r.group_id=g.id and r.status in('ready','live','paused')
   left join app_private.run_stops s on s.id=r.current_stop_id left join app_private.route_plan_stops plan on plan.id=s.plan_stop_id
   left join app_private.portals p on p.id=coalesce(s.portal_id,plan.portal_id)
   left join app_private.portal_private_locations loc on loc.portal_id=p.id
   left join app_private.group_schedule_revisions schedule on schedule.id=g.current_schedule_revision_id
   left join app_private.portal_reservations f on f.run_id=r.id and f.kind='finale' and f.status in('held','active')
   left join adults a on a.group_id=g.id left join children c on c.group_id=g.id left join leaders l on l.group_id=g.id),'[]'::jsonb),
 'portals',coalesce((select jsonb_agg(jsonb_build_object(
   'id',p.id,'code',p.system_code,'systemCode',p.system_code,'name',p.name,'operationStatus',p.operation_status,'version',p.version,
   'isFinal',p.id=cfg.final_portal_id,'activeReservations',coalesce(b.n,0),'expectedChildren',coalesce(b.children,0))
   order by p.id=cfg.final_portal_id desc,p.name)
   from app_private.portals p join app_private.event_route_settings cfg on cfg.event_id=p.event_id
   left join bookings b on b.portal_id=p.id where p.event_id=eid and p.approval_status='approved'),'[]'::jsonb),
 'alerts',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'priority',a.priority,'code',a.code,'message',a.message,
   'groupId',a.group_id,'portalId',a.portal_id,'createdAt',a.created_at)
   order by case a.priority when 'urgent' then 0 when 'warning' then 1 else 2 end,a.created_at)
   from app_private.route_alerts a where a.event_id=eid and a.status='open'),'[]'::jsonb))
 );
end $$;

create or replace function api.admin_portal_operations_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid();eid uuid;
begin
 select id into eid from app_private.events where slug=_event_slug;
 if eid is null or actor is null or not(app_private.has_capability(eid,'event_admin',actor)
   or app_private.has_capability(eid,'portals_manage',actor) or app_private.has_capability(eid,'live_support',actor))
 then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return (
 with bookings as materialized(
   select b.portal_id,count(*) n,sum(b.child_count) children from app_private.portal_reservations b
   join app_private.portals p on p.id=b.portal_id where p.event_id=eid and b.status in('held','active') group by b.portal_id
 )
 select jsonb_build_object('eventId',eid,'realtimeTopic','admin-event:'||eid::text,
 'portals',coalesce((select jsonb_agg(jsonb_build_object(
   'portalId',p.id,'applicationId',a.id,'code',p.system_code,'systemCode',p.system_code,'name',p.name,
   'world',w.name,'worldSlug',w.slug,'operationStatus',p.operation_status,'approvalStatus',p.approval_status,
   'version',p.version,'isFinal',p.id=cfg.final_portal_id,
   'contactName',nullif(trim(a.private_draft_data->>'contactName'),''),'phone',nullif(trim(a.private_draft_data->>'phone'),''),'email',u.email,
   'address',case when loc.portal_id is null then null else jsonb_build_object('street',loc.street,'houseNumber',loc.house_number,
      'addition',loc.addition,'postalCode',loc.postal_code,'city',loc.city) end,
   'formattedAddress',case when loc.portal_id is null then null else concat_ws(' ',loc.street,loc.house_number,loc.addition)||', '||loc.postal_code||' '||loc.city end,
   'locationVerified',loc.verified_at is not null,
   'coordinate',case when loc.verified_at is not null and loc.latitude is not null and loc.longitude is not null then jsonb_build_array(loc.longitude,loc.latitude) else null end,
   'messageTarget',jsonb_build_object('kind','portal','portalId',p.id,'userId',a.applicant_user_id,'label',p.system_code||' · '||p.name),
   'activeReservations',coalesce(b.n,0),'expectedChildren',coalesce(b.children,0)) order by p.system_number)
   from app_private.portals p join app_private.worlds w on w.id=p.world_id
   left join app_private.portal_applications a on a.id=p.application_id left join auth.users u on u.id=a.applicant_user_id
   left join app_private.portal_private_locations loc on loc.portal_id=p.id
   left join app_private.event_route_settings cfg on cfg.event_id=p.event_id
   left join bookings b on b.portal_id=p.id where p.event_id=eid and p.approval_status='approved'),'[]'::jsonb))
 );
end $$;
revoke all on function api.admin_evening_cockpit(text),api.admin_portal_operations_snapshot(text) from public,anon;
grant execute on function api.admin_evening_cockpit(text),api.admin_portal_operations_snapshot(text) to authenticated;
