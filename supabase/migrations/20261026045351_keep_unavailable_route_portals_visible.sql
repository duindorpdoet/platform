-- An unavailable target remains visible until its accepted intentions are repaired.
create or replace function api.admin_live_planboard_snapshot_before_worlds(_event_slug text) returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; result jsonb;
begin
 select * into e from app_private.events where slug=_event_slug for no key update;
 if auth.uid() is null or e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform app_private.live_planboard_seed(e.id);
 result:=jsonb_build_object('eventId',e.id,'eventDate',e.local_date,'generatedAt',clock_timestamp(),'inputHash',app_private.live_planboard_hash(e.id),'realtimeTopic','admin-event:'||e.id,
 'visits',app_private.live_planboard_visits(e.id),'warnings',app_private.live_planboard_warnings(e.id),
 'portals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'code',p.system_code,'world',w.name,'worldSlug',w.slug,'operationStatus',p.operation_status,'lifecycleStatus',p.lifecycle_status,'approvalStatus',p.approval_status,'finale',s.final_portal_id=p.id,
 'windows',coalesce((select jsonb_agg(jsonb_build_object('opensAt',win.opens_at,'closesAt',win.closes_at,'maxGroups',win.max_concurrent_groups,'maxChildren',win.max_children_per_visit,'durationSeconds',win.visit_minutes*60,'bufferSeconds',win.buffer_minutes*60) order by win.opens_at) from app_private.portal_windows win where win.portal_id=p.id),'[]')) order by p.system_number)
 from app_private.portals p join app_private.worlds w on w.id=p.world_id left join app_private.event_route_settings s on s.event_id=p.event_id
 where p.event_id=e.id and ((p.lifecycle_status='active' and p.approval_status='approved') or exists(select 1 from app_private.live_route_visits pending join app_private.walking_groups current_group on current_group.id=pending.group_id and current_group.retired_at is null where pending.portal_id=p.id and pending.retired_at is null) or exists(select 1 from app_private.run_stops rs join app_private.group_runs r on r.id=rs.run_id join app_private.walking_groups g on g.id=r.group_id where g.event_id=e.id and rs.portal_id=p.id))),'[]'),
 'groups',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'code',g.system_code,'name',coalesce(g.display_name,g.system_code),'version',g.version,
 'draftStartsAt',(select starts_at from app_private.start_slots where id=schedule.start_slot_id),'recipients',(select count(*) from app_private.group_adult_recipients(g.id)),'runId',r.id,'runVersion',r.version,'status',g.status,'publishedStartsAt',pub.starts_at,'scheduleId',g.current_schedule_revision_id,
 'activeChildren',case when r.id is not null then (select count(*) from app_private.run_participants rp where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null) else null end,'scheduleRevision',schedule.revision,'confirmed',app_private.is_start_confirmation_current(schedule.id),'settingsVersion',e.settings_version,
 'households',coalesce((select jsonb_agg(jsonb_build_object('reference',reg.reference,'preferredStartAt',reg.preferred_start_at,'ordinaryStopAt',reg.requested_ordinary_stop_at,'desiredEndAt',reg.desired_end_at,'childCount',(select count(*) from app_private.registration_children c where c.registration_id=reg.id and c.participation_status='active'))) from app_private.group_registrations a join app_private.registrations reg on reg.id=a.registration_id where a.group_id=g.id and a.superseded_at is null),'[]')) order by g.system_code)
 from app_private.walking_groups g left join app_private.group_runs r on r.group_id=g.id left join app_private.group_schedule_revisions schedule on schedule.id=g.current_schedule_revision_id left join lateral app_private.current_start_publication(g.id) pub on true where g.event_id=e.id and g.retired_at is null),'[]'));
 return result;
end $$;
revoke all on function api.admin_live_planboard_snapshot_before_worlds(text) from public,anon,authenticated;
