-- One event-scoped transaction for reviewed composition operations.
create or replace function app_private.dominant_start_preference(_registrations uuid[])
returns timestamptz language sql stable security definer set search_path='' as $$
 with votes as(select r.preferred_start_at t from app_private.registrations r where r.id=any(_registrations) and r.status='submitted' and r.preferred_start_at is not null)
 select t from votes group by t order by count(*) desc,
 (select sum(abs(extract(epoch from(v.t-votes.t)))) from votes v),t limit 1
$$;
create or replace function app_private.group_operations_hash(_event uuid)
returns text language sql stable security definer set search_path='' as $$
 select encode(extensions.digest(jsonb_build_object('planning',app_private.start_planning_input_hash(_event),
 'runs',(select jsonb_agg(to_jsonb(r) order by r.id) from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id where g.event_id=_event),
 'reservations',(select jsonb_agg(to_jsonb(r) order by r.id) from app_private.portal_reservations r where r.event_id=_event),
 'recipients',(select jsonb_agg(to_jsonb(m) order by m.household_id,m.user_id) from app_private.household_members m where exists(select 1 from app_private.registrations r where r.household_id=m.household_id and r.event_id=_event)),
 'communication',(select jsonb_agg(jsonb_build_array(o.id,o.status,o.provider_id) order by o.id) from app_private.email_outbox o where o.message_type in ('group_composition_confirmed','group_schedule_published','group_schedule_corrected') and exists(select 1 from app_private.walking_groups g where g.id::text=o.payload->>'groupId' and g.event_id=_event)))::text,'sha256'),'hex')
$$;
create or replace function app_private.group_adult_recipients(_group uuid)
returns table(user_id uuid,email text) language sql stable security definer set search_path='' as $$
 select distinct u.id,lower(u.email) from app_private.group_registrations a
 join app_private.registrations r on r.id=a.registration_id and r.status='submitted'
 join app_private.household_members m on m.household_id=r.household_id and m.revoked_at is null and m.accepted_at is not null and m.relation_role in ('owner','adult')
 join auth.users u on u.id=m.user_id and u.email_confirmed_at is not null and u.deleted_at is null
 where a.group_id=_group and a.superseded_at is null
$$;
create or replace function api.admin_group_operations_preview(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e app_private.events; blocked jsonb;
begin
 select * into e from app_private.events where slug=_event_slug;
 if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_object('groupId',g.id,'code',g.system_code,'reason','Deze groep heeft een gestarte run of bezoekhistorie.')),'[]') into blocked
 from app_private.walking_groups g where g.event_id=e.id and g.retired_at is null and exists(select 1 from app_private.group_runs r where r.group_id=g.id);
 return jsonb_build_object('planningInputHash',app_private.start_planning_input_hash(e.id),'inputHash',app_private.group_operations_hash(e.id),'settingsVersion',e.settings_version,
 'targetGroupSize',coalesce((e.settings->>'targetGroupSize')::integer,least(15,app_private.event_group_size_limit(e.id))),
 'maxGroupSize',app_private.event_group_size_limit(e.id),'blockers',blocked,
 'groups',(select count(*) from app_private.walking_groups g where g.event_id=e.id and g.retired_at is null),
 'registrations',(select count(*) from app_private.group_registrations a join app_private.walking_groups g on g.id=a.group_id and g.event_id=e.id and g.retired_at is null join app_private.registrations r on r.id=a.registration_id and r.status='submitted' where a.superseded_at is null),
 'children',(select count(*) from app_private.registration_children c join app_private.group_registrations a on a.registration_id=c.registration_id and a.superseded_at is null join app_private.walking_groups g on g.id=a.group_id and g.event_id=e.id and g.retired_at is null where c.participation_status='active'),
 'confirmedCompositions',(select count(*) from app_private.walking_groups g where g.event_id=e.id and g.retired_at is null and g.composition_confirmed_at is not null),
 'draftAppointments',(select count(*) from app_private.walking_groups g join app_private.group_schedule_revisions s on s.id=g.current_schedule_revision_id and s.state='draft' where g.event_id=e.id and g.retired_at is null),
 'publishedAppointments',(select count(*) from app_private.walking_groups g cross join lateral app_private.current_start_publication(g.id) p where g.event_id=e.id),
 'reservations',(select count(*) from app_private.portal_reservations r where r.event_id=e.id and r.status in ('held','active')),
 'communicationRecipients',(select count(distinct rec.user_id) from app_private.walking_groups g cross join lateral app_private.group_adult_recipients(g.id) rec where g.event_id=e.id and g.retired_at is null and (g.composition_confirmed_at is not null or exists(select 1 from app_private.current_start_publication(g.id)))));
end $$;

create or replace function app_private.withdraw_group_appointment(_group uuid,_reason text)
returns void language plpgsql security definer set search_path='' as $$
declare g app_private.walking_groups;
begin
 select * into g from app_private.walking_groups where id=_group;
 insert into app_private.group_start_withdrawals(event_id,group_id,through_publication_order,actor_id,reason)
 select g.event_id,g.id,max(publication_order),auth.uid(),_reason from app_private.group_start_publications where group_id=g.id having max(publication_order) is not null;
 update app_private.group_schedule_revisions set state='superseded' where group_id=g.id and state in ('draft','published');
 update app_private.route_plan_versions set state='superseded' where group_id=g.id and state='draft';
 update app_private.portal_reservations set status='cancelled',cancelled_reason=_reason,version=version+1 where group_id=g.id and status in ('held','active');
 update app_private.email_outbox set status='suppressed',last_error_code='GROUP_ASSIGNMENT_WITHDRAWN',lease_until=null
 where payload->>'groupId'=g.id::text and message_type in ('group_composition_confirmed','group_schedule_published','group_schedule_corrected') and status in ('pending','deferred','processing');
 update app_private.walking_groups set current_schedule_revision_id=null,current_plan_version_id=null,start_slot_id=null where id=g.id;
end $$;

create or replace function api.admin_group_operations_apply(_event_slug text,_action text,_input_hash text,_payload jsonb,_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e app_private.events; g app_private.walking_groups; item jsonb; reg uuid; member record; recipient record;
 receipt app_private.command_receipts; request_hash text; result jsonb; created jsonb; ids uuid[]; seen uuid[]:='{}';
 affected uuid[]; count_children integer; next_rev integer; schedule_ids uuid[]:='{}'; slot app_private.start_slots;
begin
 select * into e from app_private.events where slug=_event_slug for update;
 if e.id is null or not app_private.has_capability(e.id,'groups_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;

 perform pg_advisory_xact_lock(hashtextextended(e.id::text||':route-dispatch',0));
 if length(coalesce(_idempotency_key,'')) not between 16 and 200 or _action not in ('reset','autofill','confirm','reopen','distribute','move','create','repair') then raise exception 'VALIDATION_ERROR' using errcode='22023'; end if;
 request_hash:=encode(extensions.digest(jsonb_build_object('event',e.id,'action',_action,'inputHash',_input_hash,'payload',_payload)::text,'sha256'),'hex');
 select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='groups.'||_action and idempotency_key=_idempotency_key;
 if receipt.id is not null then
  if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='23505';end if;
  return receipt.safe_result;
 end if;
 if _input_hash is distinct from app_private.group_operations_hash(e.id) then raise exception 'STALE_GROUP_INPUT' using errcode='40001',hint='Vernieuw de impact of bereken het voorstel opnieuw.';end if;
 perform 1 from app_private.walking_groups where event_id=e.id order by id for update;
 if _action in ('reset','autofill','reopen') and e.phase not in ('draft','registration_open','registration_closed','planning') then raise exception 'GROUPS_FINALIZED' using errcode='23514';end if;
 if _action='move' then
  result:=api.admin_group_move_registration(_event_slug,(_payload->>'registrationId')::uuid,(_payload->>'targetGroupId')::uuid);
 elsif _action='create' then
  result:=api.admin_group_create(_event_slug,_payload->>'displayName');
 elsif _action='repair' then
  result:=api.admin_group_repair_split_party(_event_slug,(_payload->>'partyId')::uuid);
 elsif _action='reset' then
  if _payload->>'confirmation' is distinct from 'ALLE GROEPEN TERUGZETTEN' then raise exception 'RESET_CONFIRMATION_REQUIRED' using errcode='22023';end if;
  select array_agg(id order by id) into affected from app_private.walking_groups where event_id=e.id and retired_at is null;
  if exists(select 1 from app_private.group_runs where group_id=any(affected)) then raise exception 'RESET_BLOCKED_STARTED_GROUP' using errcode='23514',detail=(api.admin_group_operations_preview(_event_slug)->'blockers')::text;end if;
  -- Queue one personal withdrawal per adult across all affected groups, before ending membership.
  for recipient in select distinct rec.* from app_private.walking_groups current_group cross join lateral app_private.group_adult_recipients(current_group.id) rec
   where current_group.id=any(affected) and (current_group.composition_confirmed_at is not null or exists(select 1 from app_private.current_start_publication(current_group.id))) loop
   insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
   values('group-reset:'||e.id||':'||_idempotency_key||':'||recipient.user_id,'group_assignment_withdrawn',recipient.user_id::text,recipient.email,
    jsonb_build_object('eventId',e.id,'actionPath','/omgeving/meeloper/groep')) on conflict(dedupe_key) do nothing;
  end loop;
  foreach reg in array coalesce(affected,'{}'::uuid[]) loop perform app_private.withdraw_group_appointment(reg,'Alle groepen teruggezet na actuele impactcontrole');end loop;
  update app_private.walking_groups set composition_confirmed_hash=null where id=any(affected);
  update app_private.group_registrations set superseded_at=clock_timestamp() where group_id=any(affected) and superseded_at is null;
  update app_private.group_leaders set active_until=greatest(clock_timestamp(),active_from+interval '1 microsecond') where group_id=any(affected) and active_until is null;
  update app_private.group_viewer_access set revoked_at=clock_timestamp() where group_id=any(affected) and revoked_at is null;
  update app_private.walking_groups set status='retired',retired_at=clock_timestamp(),composition_confirmed_hash=null,version=version+1 where id=any(affected);
  update app_private.registrations set preference_change_status='editable' where event_id=e.id and status='submitted' and not exists(select 1 from app_private.group_registrations a where a.registration_id=registrations.id and a.superseded_at is null);
  result:=jsonb_build_object('retiredGroups',coalesce(cardinality(affected),0));
 elsif _action='autofill' then
  if jsonb_typeof(_payload->'groups') is distinct from 'array' or jsonb_array_length(_payload->'groups')>500 then raise exception 'INVALID_PLAN' using errcode='22023';end if;
  for item in select * from jsonb_array_elements(_payload->'groups') loop
   select array_agg(value::uuid order by value) into ids from jsonb_array_elements_text(item->'registrationIds');
   if coalesce(cardinality(ids),0)=0 or exists(select 1 from unnest(ids) id where id=any(seen)) then raise exception 'DUPLICATE_OR_EMPTY_BLOCK' using errcode='23514';end if;
   if (select count(*) from app_private.registrations r where r.id=any(ids) and r.event_id=e.id and r.status='submitted' and not exists(select 1 from app_private.group_registrations a where a.registration_id=r.id and a.superseded_at is null))<>cardinality(ids) then raise exception 'INVALID_REGISTRATION' using errcode='23514';end if;
   if exists(select 1 from app_private.together_memberships m join app_private.together_memberships sibling on sibling.party_id=m.party_id and sibling.left_at is null join app_private.registrations r on r.id=sibling.registration_id and r.status='submitted' where m.registration_id=any(ids) and m.left_at is null and not(sibling.registration_id=any(ids))) then raise exception 'TOGETHER_PARTY_SPLIT' using errcode='23514';end if;
   select count(*) into count_children from app_private.registration_children c where c.registration_id=any(ids) and c.participation_status='active';
   if count_children<1 then raise exception 'EMPTY_GROUP' using errcode='23514';end if;
   -- An oversized intact block stays visible as a draft requiring an audited policy decision.
   if count_children>app_private.event_group_size_limit(e.id) and (select count(distinct coalesce(m.party_id::text,r.id::text)) from app_private.registrations r left join app_private.together_memberships m on m.registration_id=r.id and m.left_at is null where r.id=any(ids))<>1 then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514';end if;
   created:=api.admin_group_create(_event_slug,null);
   foreach reg in array ids loop
    select coalesce(max(assignment_revision),0)+1 into next_rev from app_private.group_registrations where registration_id=reg;
    insert into app_private.group_registrations(group_id,registration_id,assignment_revision) values((created->>'id')::uuid,reg,next_rev);
   end loop;
   insert into app_private.group_leaders(group_id,user_id,active_from,revision,assigned_by)
   select (created->>'id')::uuid,rec.user_id,clock_timestamp(),1,auth.uid() from app_private.group_adult_recipients((created->>'id')::uuid) rec order by rec.user_id limit 1;
   seen:=seen||ids;
  end loop;
  if exists(select 1 from app_private.registrations r where r.event_id=e.id and r.status='submitted' and exists(select 1 from app_private.registration_children c where c.registration_id=r.id and c.participation_status='active') and not exists(select 1 from app_private.group_registrations a where a.registration_id=r.id and a.superseded_at is null)) then raise exception 'INCOMPLETE_GROUP_PLAN' using errcode='23514';end if;
  result:=jsonb_build_object('createdGroups',jsonb_array_length(_payload->'groups'),'registrations',cardinality(seen));
 elsif _action in ('confirm','reopen') then
  select * into g from app_private.walking_groups where id=(_payload->>'groupId')::uuid and event_id=e.id and retired_at is null;
  if g.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  if exists(select 1 from app_private.group_runs where group_id=g.id) then raise exception 'GROUP_ALREADY_STARTED' using errcode='23514';end if;
  if _action='confirm' then
   select count(*) into count_children from app_private.group_registrations a join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active' where a.group_id=g.id and a.superseded_at is null;
   if count_children<1 then raise exception 'EMPTY_GROUP' using errcode='23514';end if;
   if count_children>app_private.event_group_size_limit(e.id) then raise exception 'GROUP_SIZE_LIMIT_EXCEEDED' using errcode='23514';end if;
   if g.composition_confirmed_hash is distinct from app_private.start_group_composition_hash(g.id) then
    update app_private.walking_groups set composition_confirmed_hash=app_private.start_group_composition_hash(id),composition_confirmed_at=clock_timestamp(),composition_confirmed_by=auth.uid(),composition_revision=composition_revision+1,version=version+1 where id=g.id returning * into g;
    update app_private.email_outbox set status='suppressed',last_error_code='COMPOSITION_SUPERSEDED' where message_type='group_composition_confirmed' and payload->>'groupId'=g.id::text and status in ('pending','deferred');
   end if;
    for recipient in select * from app_private.group_adult_recipients(g.id) loop
     insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload)
     values('group-composition:'||g.id||':'||g.composition_revision||':'||recipient.user_id,'group_composition_confirmed',recipient.user_id::text,recipient.email,
      jsonb_build_object('groupId',g.id,'compositionRevision',g.composition_revision,'compositionHash',g.composition_confirmed_hash,'groupName',coalesce(g.display_name,g.system_code),'groupCode',g.system_code,'actionPath','/omgeving/meeloper/groep')) on conflict(dedupe_key) do nothing;
    end loop;
   result:=jsonb_build_object('groupId',g.id,'compositionRevision',g.composition_revision,'confirmedAt',g.composition_confirmed_at);
  else
   if length(trim(coalesce(_payload->>'reason','')))<10 then raise exception 'REASON_REQUIRED' using errcode='22023';end if;
   perform app_private.withdraw_group_appointment(g.id,_payload->>'reason');
   update app_private.walking_groups set composition_confirmed_hash=null where id=g.id;
   -- Retain historical memberships, and reopen the same registration/group identities.
   for member in select * from app_private.group_registrations where group_id=g.id and superseded_at is null loop
    update app_private.group_registrations set superseded_at=clock_timestamp() where id=member.id;
    insert into app_private.group_registrations(group_id,registration_id,assignment_revision) values(g.id,member.registration_id,member.assignment_revision+1);
   end loop;
   update app_private.walking_groups set status='draft',composition_confirmed_hash=null,composition_confirmed_at=null,composition_confirmed_by=null,version=version+1 where id=g.id;
   result:=jsonb_build_object('groupId',g.id,'reopened',true);
  end if;
 elsif _action='distribute' then
  if jsonb_typeof(_payload->'groups') is distinct from 'array' then raise exception 'INVALID_PLAN' using errcode='22023';end if;
  for item in select * from jsonb_array_elements(_payload->'groups') loop
   select * into g from app_private.walking_groups where id=(item->>'key')::uuid and event_id=e.id and retired_at is null;
   if g.id is null or g.status<>'draft' or g.id=any(seen) or exists(select 1 from app_private.group_schedule_revisions s where s.id=g.current_schedule_revision_id and (s.confirmed_at is not null or s.state='published')) then raise exception 'START_APPOINTMENT_PROTECTED' using errcode='23514';end if;
   if exists(select 1 from app_private.current_start_publication(g.id)) then raise exception 'START_APPOINTMENT_PROTECTED' using errcode='23514';end if;
   select * into slot from app_private.start_slots where id=(item->>'startId')::uuid and event_id=e.id and active;
   if slot.id is null then raise exception 'INVALID_START' using errcode='23514';end if;
   created:=api.admin_startregie_move_group(g.id,slot.start_point_id,slot.starts_at,g.version,coalesce(item->>'preferenceMatch','neutral'),'Automatische slotverdeling na actuele preview');
   update app_private.group_schedule_revisions set expected_finale_arrival_at=(item->>'expectedFinaleArrivalAt')::timestamptz where id=(created->>'id')::uuid;
   schedule_ids:=array_append(schedule_ids,(created->>'id')::uuid);seen:=array_append(seen,g.id);
  end loop;
  perform app_private.validate_start_schedule_capacity(e.id,schedule_ids);
  result:=jsonb_build_object('plannedGroups',cardinality(schedule_ids),'scheduleIds',schedule_ids);
 end if;
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,minimal_change) values(e.id,auth.uid(),'groups.'||_action,'group_operations',jsonb_build_object('inputHash',_input_hash,'result',result,'reason',_payload->>'reason'));
 insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at) values(auth.uid(),'groups.'||_action,_idempotency_key,request_hash,result,now()+interval '7 days');
 perform realtime.send(jsonb_build_object('resource','group_composition'),'snapshot_changed','admin-event:'||e.id,true);
 return result;
end $$;
revoke all on function app_private.dominant_start_preference(uuid[]),app_private.group_operations_hash(uuid),app_private.group_adult_recipients(uuid),app_private.withdraw_group_appointment(uuid,text) from public,anon,authenticated;
revoke all on function api.admin_group_operations_preview(text),api.admin_group_operations_apply(text,text,text,jsonb,text) from public,anon;
grant execute on function api.admin_group_operations_preview(text),api.admin_group_operations_apply(text,text,text,jsonb,text) to authenticated;
