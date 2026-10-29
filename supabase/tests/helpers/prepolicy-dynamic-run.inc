-- A synthetic journey already underway when joint routing was introduced.
-- This prepares historical rows; policy and application guards stay unchanged.
-- New run_start authorization/review is independently exercised in 069/111.
create function pg_temp.prepolicy_dynamic_run(_group uuid,_present uuid[],_expected_version integer,_key text,_request_hash text)returns jsonb
language plpgsql security definer set search_path=''as $$
declare g app_private.walking_groups;rid uuid;result jsonb;sid uuid;
begin
 if not app_private.is_current_leader(_group,auth.uid())then raise exception 'NOT_AUTHORIZED'using errcode='42501';end if;
 select *into g from app_private.walking_groups where id=_group for update;
 if g.version<>_expected_version then raise exception 'STALE_VERSION'using errcode='40001';end if;
 if cardinality(_present)<1 or exists(select 1 from unnest(_present)supplied(id) where not exists(select 1 from app_private.registration_children rc join app_private.group_registrations a on a.registration_id=rc.registration_id where rc.id=supplied.id and a.group_id=_group and a.superseded_at is null and rc.participation_status='active'))then raise exception 'INVALID_ROSTER'using errcode='23514';end if;
 sid:=(app_private.route_group_start_context(_group)->>'scheduleId')::uuid;
 insert into app_private.group_runs(group_id,schedule_revision_id,status,started_at)
 select _group,sid,'live',activated_at-interval '1 minute'from app_private.joint_route_policy_releases where policy_version='joint-reception-v1'returning id into rid;
 insert into app_private.run_participants(run_id,registration_child_id,attendance)
 select rid,rc.id,case when rc.id=any(_present)then 'present'::app_private.attendance_status else 'absent'::app_private.attendance_status end
 from app_private.registration_children rc join app_private.group_registrations a on a.registration_id=rc.registration_id where a.group_id=_group and a.superseded_at is null and rc.participation_status='active';
 update app_private.walking_groups set status='live',version=version+1 where id=_group;
 result:=app_private.dispatch_next_stop(rid,clock_timestamp());
 return jsonb_build_object('runId',rid,'dispatch',result);
end $$;
