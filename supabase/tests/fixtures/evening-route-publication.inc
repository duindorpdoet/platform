-- Test adapter: obtain real authorized route fingerprints before invoking the
-- new publication contract. No production endpoint bypasses this requirement.
create or replace function pg_temp.publish_fingerprinted(_event text,_ids uuid[],_revisions jsonb,_settings integer,_key text,_reason text default 'Geselecteerde starttijden en gecontroleerde routes publiceren') returns jsonb
language plpgsql security definer set search_path='' as $$
declare fingerprints jsonb;
begin
 select coalesce(jsonb_agg(jsonb_build_object('groupId',s.group_id,'fingerprint',api.admin_startregie_route_preview(_event,s.group_id)->>'fingerprint') order by s.group_id),'[]') into fingerprints from app_private.group_schedule_revisions s where s.id=any(_ids);
 return api.admin_startregie_publish_times(_event,_ids,_revisions,_settings,_key,fingerprints,_reason);
end $$;
grant execute on function pg_temp.publish_fingerprinted(text,uuid[],jsonb,integer,text,text) to authenticated;
