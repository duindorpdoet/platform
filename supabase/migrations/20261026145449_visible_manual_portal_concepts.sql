-- Manual concepts are actual portal records, not resident intake/application
-- rows. Include them explicitly in the organization's overview and counts.
alter function api.admin_portal_management_snapshot(text) rename to admin_portal_management_snapshot_before_manual_concepts;
revoke all on function api.admin_portal_management_snapshot_before_manual_concepts(text) from public,anon,authenticated;
create function api.admin_portal_management_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  result:=api.admin_portal_management_snapshot_before_manual_concepts(_event_slug);
  return result||jsonb_build_object('conceptPortals',coalesce((
    select jsonb_agg(jsonb_build_object('id',p.id,'code',p.system_code,'name',p.name,'isFinal',p.id=s.final_portal_id) order by p.system_number)
    from app_private.portals p join app_private.events e on e.id=p.event_id
    left join app_private.event_route_settings s on s.event_id=e.id
    where e.slug=_event_slug and p.record_source='manual' and p.lifecycle_status in ('concept','registered') and p.approval_status not in ('withdrawn','rejected')
  ),'[]'::jsonb));
end $$;
revoke all on function api.admin_portal_management_snapshot(text) from public,anon;
grant execute on function api.admin_portal_management_snapshot(text) to authenticated;
