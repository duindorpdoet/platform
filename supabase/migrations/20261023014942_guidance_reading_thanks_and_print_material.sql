-- All new participant state stays in the existing private schema.
set lock_timeout = '5s';
create table if not exists app_private.community_acknowledgements (
 event_id uuid not null references app_private.events(id), user_id uuid not null references auth.users(id),
 local_day date not null, acknowledged_at timestamptz not null default now(), primary key(event_id,user_id,local_day)
);
create table if not exists app_private.participant_tutorials (
 event_id uuid not null references app_private.events(id),user_id uuid not null references auth.users(id),
 role text not null check(role in ('parent','house')),version integer not null default 1,
 last_step integer not null default 0 check(last_step between 0 and 13),furthest_step integer not null default 0 check(furthest_step between 0 and 13),
 return_path text not null default '/omgeving',completed_at timestamptz,updated_at timestamptz not null default now(),
 primary key(event_id,user_id,role,version)
);
create table if not exists app_private.poortenboek_tutorials (
 event_id uuid not null references app_private.events(id),child_id uuid not null references app_private.children(id),version integer not null default 1,
 last_step integer not null default 0 check(last_step between 0 and 8),furthest_step integer not null default 0 check(furthest_step between 0 and 8),completed_at timestamptz,
 primary key(event_id,child_id,version)
);
create table if not exists app_private.poortenboek_chapter_reads (
 event_id uuid not null references app_private.events(id),child_id uuid not null references app_private.children(id),chapter integer not null check(chapter between 1 and 6),read_at timestamptz not null default now(),
 primary key(event_id,child_id,chapter)
);
create table if not exists app_private.portal_thanks (
 event_id uuid not null references app_private.events(id),household_id uuid not null references app_private.households(id),portal_id uuid not null references app_private.portals(id),
 choice text not null check(choice in ('beautiful','welcome','treats')),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 primary key(event_id,household_id,portal_id)
);
create index if not exists portal_thanks_portal on app_private.portal_thanks(event_id,portal_id);
create table if not exists app_private.portal_print_material (
 credential_id uuid primary key references app_private.portal_credentials(id),ciphertext text not null,created_at timestamptz not null default now()
);
alter table app_private.community_acknowledgements enable row level security;
revoke all on app_private.community_acknowledgements from public,anon,authenticated;
alter table app_private.participant_tutorials enable row level security;
revoke all on app_private.participant_tutorials from public,anon,authenticated;
alter table app_private.poortenboek_tutorials enable row level security;
revoke all on app_private.poortenboek_tutorials from public,anon,authenticated;
alter table app_private.poortenboek_chapter_reads enable row level security;
revoke all on app_private.poortenboek_chapter_reads from public,anon,authenticated;
alter table app_private.portal_thanks enable row level security;
revoke all on app_private.portal_thanks from public,anon,authenticated;
alter table app_private.portal_print_material enable row level security;
revoke all on app_private.portal_print_material from public,anon,authenticated;

create or replace function api.participant_guidance(_event_slug text,_action text default 'snapshot',_role text default null,_payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb; eventid uuid; roles jsonb; today date:=(now() at time zone 'Europe/Amsterdam')::date; record app_private.participant_tutorials; step integer; original text;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 ctx:=api.participant_context(_event_slug);eventid:=(ctx->'event'->>'id')::uuid;
 select coalesce(jsonb_agg(distinct case item->>'key' when 'walker' then 'parent' when 'homeowner' then 'house' else 'viewer' end),'[]'::jsonb)
 into roles from jsonb_array_elements(ctx->'roles') item;
 if eventid is null or jsonb_array_length(roles)=0 then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _action='acknowledge' then
  insert into app_private.community_acknowledgements(event_id,user_id,local_day) values(eventid,auth.uid(),today) on conflict do nothing;
 elsif _action='tutorial' then
  if _role not in ('parent','house') or not roles ? _role or (_payload->>'version')::integer is distinct from 1 then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  step:=(_payload->>'index')::integer;original:=_payload->>'returnPath';
  if step is null or step not between 0 and 13 or original is null or original !~ '^/[^/]' or original ~ '[[:cntrl:]]' or char_length(original)>4096 then raise exception 'INVALID_INPUT'; end if;
  insert into app_private.participant_tutorials(event_id,user_id,role,return_path) values(eventid,auth.uid(),_role,original) on conflict do nothing;
  select * into record from app_private.participant_tutorials where event_id=eventid and user_id=auth.uid() and role=_role and version=1 for update;
  if step>record.furthest_step+1 or (coalesce((_payload->>'completed')::boolean,false) and (step<>13 or record.furthest_step<13)) then raise exception 'TUTORIAL_STEP_REQUIRED'; end if;
  update app_private.participant_tutorials set last_step=step,furthest_step=greatest(furthest_step,step),return_path=original,
  completed_at=case when coalesce((_payload->>'completed')::boolean,false) then coalesce(completed_at,now()) else completed_at end,updated_at=now()
  where event_id=eventid and user_id=auth.uid() and role=_role and version=1;
 elsif _action<>'snapshot' then raise exception 'INVALID_INPUT'; end if;
 return jsonb_build_object('groupId',(select item->>'groupId' from jsonb_array_elements(ctx->'roles') item where item->>'key'='walker' limit 1),'userId',auth.uid(),'eventId',eventid,'roles',roles,'today',today,'acknowledgedDay',
  (select local_day from app_private.community_acknowledgements where event_id=eventid and user_id=auth.uid() and local_day=today),
  'completed',coalesce((select jsonb_object_agg(role,version) from app_private.participant_tutorials where event_id=eventid and user_id=auth.uid() and completed_at is not null),'{}'::jsonb),
  'progress',coalesce((select jsonb_object_agg(role,jsonb_build_object('version',version,'index',last_step,'returnPath',return_path)) from app_private.participant_tutorials where event_id=eventid and user_id=auth.uid() and completed_at is null),'{}'::jsonb));
end $$;
revoke all on function api.participant_guidance(text,text,text,jsonb) from public,anon;
grant execute on function api.participant_guidance(text,text,text,jsonb) to authenticated;

create or replace function api.portal_thanks_snapshot(_event_slug text,_scope text default 'family',_portal_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare eventid uuid; homeid uuid; result jsonb; finished boolean;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select id into eventid from app_private.events where slug=_event_slug;
 if eventid is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _scope='family' then
  select reg.household_id into homeid from app_private.registrations reg where reg.event_id=eventid and app_private.is_household_member(reg.household_id,auth.uid()) order by reg.created_at limit 1;
  if homeid is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  finished:=exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id join app_private.registrations reg on reg.id=rc.registration_id
   join app_private.group_runs r on r.id=rp.run_id where reg.event_id=eventid and reg.household_id=homeid and (rp.departure_reason='early' or r.status='completed'))
   and not exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id join app_private.registrations reg on reg.id=rc.registration_id
   join app_private.group_runs r on r.id=rp.run_id where reg.event_id=eventid and reg.household_id=homeid and rp.attendance='present' and r.status in ('live','paused'));
  return jsonb_build_object('finished',finished,'portals',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'world',w.name) order by p.name)
   from app_private.portals p join app_private.worlds w on w.id=p.world_id where p.event_id=eventid and exists(
    select 1 from app_private.run_stop_arrivals a join app_private.registration_children rc on rc.child_id=a.child_id join app_private.registrations reg on reg.id=rc.registration_id
    join app_private.run_stops st on st.id=a.run_stop_id left join app_private.route_plan_stops plan on plan.id=st.plan_stop_id
    where a.event_id=eventid and reg.event_id=eventid and reg.household_id=homeid and a.arrived and p.id=coalesce(st.portal_id,plan.portal_id))), '[]'::jsonb),
   'saved',coalesce((select jsonb_agg(jsonb_build_object('portalId',portal_id,'choice',choice)) from app_private.portal_thanks where event_id=eventid and household_id=homeid),'[]'::jsonb));
 end if;
 if _scope='admin' then
  if not app_private.has_capability(eventid,'live_support',auth.uid()) and not app_private.has_capability(eventid,'event_admin',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 elsif _scope='house' then
  if _portal_id is null or not exists(select 1 from app_private.portals p join app_private.portal_owners o on o.portal_id=p.id where p.id=_portal_id and p.event_id=eventid and o.user_id=auth.uid() and o.revoked_at is null and o.suspended_at is null)
   and not app_private.has_capability(eventid,'portals_manage',auth.uid()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 else raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select jsonb_build_object('familyCount',count(distinct t.household_id),'thanks',coalesce(jsonb_agg(jsonb_build_object('portalId',t.portal_id,'portalName',p.name,'world',w.name,'choice',t.choice) order by p.name,t.choice),'[]'::jsonb)) into result
 from app_private.portal_thanks t join app_private.portals p on p.id=t.portal_id join app_private.worlds w on w.id=p.world_id
 where t.event_id=eventid and (_scope='admin' or t.portal_id=_portal_id);
 return result;
end $$;

create or replace function api.portal_thanks_save(_event_slug text,_portal_id uuid,_choice text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare snapshot jsonb; eventid uuid; homeid uuid;
begin
 snapshot:=api.portal_thanks_snapshot(_event_slug,'family');
 if not coalesce((snapshot->>'finished')::boolean,false) or not exists(select 1 from jsonb_array_elements(snapshot->'portals') p where (p->>'id')::uuid=_portal_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if _choice not in ('beautiful','welcome','treats') then raise exception 'INVALID_INPUT'; end if;
 select id into eventid from app_private.events where slug=_event_slug;
 select household_id into homeid from app_private.registrations where event_id=eventid and app_private.is_household_member(household_id,auth.uid()) order by created_at limit 1;
 insert into app_private.portal_thanks(event_id,household_id,portal_id,choice) values(eventid,homeid,_portal_id,_choice)
 on conflict(event_id,household_id,portal_id) do update set choice=excluded.choice,updated_at=now();
 return jsonb_build_object('ok',true);
end $$;
revoke all on function api.portal_thanks_snapshot(text,text,uuid),api.portal_thanks_save(text,uuid,text) from public,anon;
grant execute on function api.portal_thanks_snapshot(text,text,uuid),api.portal_thanks_save(text,uuid,text) to authenticated;

-- Print material is only decrypted by the authenticated Next server.
create or replace function api.portal_print_access(_actor uuid,_portal_id uuid,_action text default 'read',_expected_version integer default null,_ciphertext text default null,_token_hash bytea default null,_short_hash bytea default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p app_private.portals; c app_private.portal_credentials; nextversion integer;
begin
 if _actor is null then raise exception 'NOT_AUTHORIZED'; end if;
 select * into p from app_private.portals where id=_portal_id for update;
 if p.id is null or not exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.user_id=_actor and o.revoked_at is null and o.suspended_at is null)
 and not app_private.has_capability(p.event_id,'portals_manage',_actor) then raise exception 'NOT_AUTHORIZED'; end if;
 if _action='rotate' then
  if not exists(select 1 from app_private.portal_owners o where o.portal_id=p.id and o.user_id=_actor and o.revoked_at is null and o.suspended_at is null and o.access_level='manage') and not app_private.has_capability(p.event_id,'portals_manage',_actor) then raise exception 'NOT_AUTHORIZED'; end if;
  if p.version is distinct from _expected_version then raise exception 'STALE_VERSION'; end if;
  if p.approval_status<>'approved' or _ciphertext is null or octet_length(_token_hash)<>32 or octet_length(_short_hash)<>32 then raise exception 'INVALID_INPUT'; end if;
  select coalesce(max(version),0)+1 into nextversion from app_private.portal_credentials where portal_id=p.id;
  update app_private.portal_credentials set revoked_at=now() where portal_id=p.id and revoked_at is null;
  insert into app_private.portal_credentials(portal_id,version,token_hash,short_code_hash,valid_from) values(p.id,nextversion,_token_hash,_short_hash,now()) returning * into c;
  insert into app_private.portal_print_material(credential_id,ciphertext) values(c.id,_ciphertext);
  update app_private.portals set version=version+1 where id=p.id returning * into p;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
  values(p.event_id,_actor,'portal.credential_rotated','portal',p.id,jsonb_build_object('credentialVersion',c.version,'reason','Expliciet vernieuwd in QR & printen'));
 elsif _action='read' then
  select * into c from app_private.portal_credentials where portal_id=p.id and revoked_at is null and valid_from<=now() and (valid_until is null or valid_until>now()) order by version desc limit 1;
 else raise exception 'INVALID_INPUT'; end if;
 return jsonb_build_object('credentialId',c.id,'credentialRevision',c.version,'portalVersion',p.version,
  'ciphertext',(select ciphertext from app_private.portal_print_material where credential_id=c.id),
  'legacy',c.id is not null and not exists(select 1 from app_private.portal_print_material where credential_id=c.id),
  'eventDate',(select local_date from app_private.events where id=p.event_id));
end $$;
revoke all on function api.portal_print_access(uuid,uuid,text,integer,text,bytea,bytea) from public,anon,authenticated;
grant execute on function api.portal_print_access(uuid,uuid,text,integer,text,bytea,bytea) to service_role;
create or replace function app_private.poortenboek_snapshot(_session app_private.poortenboek_sessions) returns jsonb
language plpgsql set search_path='' as $$
declare base jsonb; c app_private.poortenboek_codes; team uuid; identity app_private.poortenboek_child_identity;
  banner jsonb; visits integer; assigned integer; phase text;
begin
  base:=app_private.poortenboek_snapshot_v1(_session);
  select * into c from app_private.poortenboek_codes where id=_session.code_id;
  team:=app_private.poortenboek_team(c.event_id,c.child_id);
  insert into app_private.poortenboek_child_identity(event_id,child_id) values(c.event_id,c.child_id) on conflict do nothing;
  select * into identity from app_private.poortenboek_child_identity where event_id=c.event_id and child_id=c.child_id;
  insert into app_private.poortenboek_story_chapters(event_id,child_id,chapter) values(c.event_id,c.child_id,1) on conflict do nothing;
  banner:=app_private.poortenboek_resolve_banner(c.event_id,team);
  select count(*) into visits from app_private.poortenboek_passport_seals where event_id=c.event_id and child_id=c.child_id;
  select count(*) into assigned from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id
    join app_private.walking_groups g on g.id=r.group_id join app_private.group_registrations gr on gr.group_id=g.id and gr.superseded_at is null
    join app_private.registration_children rc on rc.registration_id=gr.registration_id and rc.child_id=c.child_id where g.event_id=c.event_id;
  select e.phase::text into phase from app_private.events e where e.id=c.event_id;

  return base||jsonb_build_object(
    'childId',c.child_id,'eventId',c.event_id,
    'farewell',(select jsonb_build_object('endedAt',rp.departed_at,'reason','early') from app_private.run_participants rp
      join app_private.registration_children rc on rc.id=rp.registration_child_id where rc.child_id=c.child_id and rc.event_id=c.event_id and rp.departure_reason='early' order by rp.departed_at desc limit 1),
    'reading',jsonb_build_object('readChapters',coalesce((select jsonb_agg(chapter order by chapter) from app_private.poortenboek_chapter_reads where event_id=c.event_id and child_id=c.child_id),'[]'::jsonb)),
    'tutorial',coalesce((select jsonb_build_object('version',version,'completedAt',completed_at,'lastStep',last_step) from app_private.poortenboek_tutorials where event_id=c.event_id and child_id=c.child_id and version=1),jsonb_build_object('version',1,'completedAt',null,'lastStep',0)),
    'companions',coalesce((select jsonb_agg(jsonb_build_object('firstName',m.first_name,
      'medallion',get_byte(extensions.digest(m.child_id::text,'sha256'),0)%6,
      'avatarId',coalesce(i.avatar_id,'nightwatcher'),'lanternShape',coalesce(i.lantern_shape,'classic'),'lanternColor',coalesce(i.lantern_color,'amber'),
      'status',case when exists(select 1 from app_private.group_registrations a join app_private.group_runs run on run.group_id=a.group_id where a.registration_id=m.registration_id and a.superseded_at is null and run.status='completed') then 'completed'
        when exists(select 1 from app_private.group_registrations a join app_private.group_runs run on run.group_id=a.group_id where a.registration_id=m.registration_id and a.superseded_at is null and run.status='live') then 'underway'
        when progress.checklist=array[true,true,true,true,true,true] then 'ready' else 'preparing' end) order by m.first_name,m.child_id)
      from app_private.poortenboek_members(c.event_id,team) m
      left join app_private.poortenboek_progress progress on progress.event_id=c.event_id and progress.child_id=m.child_id
      left join app_private.poortenboek_child_identity i on i.event_id=c.event_id and i.child_id=m.child_id),'[]'::jsonb),
    'worlds',coalesce((select jsonb_agg(jsonb_build_object('slug',w.slug,'name',w.name,'story',w.story,
      'unlocked',exists(select 1 from app_private.poortenboek_passport_seals seal where seal.event_id=c.event_id and seal.child_id=c.child_id and seal.world_id=w.id)) order by w.sort_order)
      from app_private.worlds w where w.event_id=c.event_id),'[]'::jsonb),
    'identity',jsonb_build_object('avatarId',identity.avatar_id,'lanternShape',identity.lantern_shape,'lanternColor',identity.lantern_color),
    'practice',jsonb_build_object('completed',exists(select 1 from app_private.poortenboek_practice where event_id=c.event_id and child_id=c.child_id)),
    'banner',jsonb_build_object('options',app_private.poortenboek_banner_options(),
      'ownVote',coalesce((select choices from app_private.poortenboek_banner_votes where event_id=c.event_id and team_id=team and child_id=c.child_id),'{}'::jsonb),
      'votedCount',(select count(*) from app_private.poortenboek_banner_votes where event_id=c.event_id and team_id=team),
      'eligibleCount',(select count(*) from app_private.poortenboek_members(c.event_id,team)),
      'result',banner,'locked',phase in ('live','paused','completed','archived')),
    'journey',jsonb_build_object('visitedCount',visits,'assignedCount',assigned,'upgradeLevel',case when visits>=greatest(assigned,1) then 4 when visits>=5 then 3 when visits>=3 then 2 when visits>=1 then 1 else 0 end,
      'chapters',coalesce((select jsonb_agg(jsonb_build_object('chapter',chapter,'unlockedAt',unlocked_at) order by chapter) from app_private.poortenboek_story_chapters where event_id=c.event_id and child_id=c.child_id and (chapter<6 or exists(select 1 from app_private.poortenboek_passport_seals ps where ps.event_id=c.event_id and ps.child_id=c.child_id and ps.finale))),'[]'::jsonb),
      'seals',coalesce((select jsonb_agg(jsonb_build_object('stopId',s.run_stop_id,'portalId',s.portal_id,'worldId',s.world_id,'earnedAt',s.earned_at,'finale',s.finale,'presentation',s.presentation_snapshot) order by s.earned_at) from app_private.poortenboek_passport_seals s where s.event_id=c.event_id and s.child_id=c.child_id),'[]'::jsonb),
      'complete',exists(select 1 from app_private.poortenboek_passport_seals where event_id=c.event_id and child_id=c.child_id and finale)),
    'v2',true);
end $$;
create or replace function api.poortenboek_child_action(_token_hash text,_action text,_payload jsonb default '{}',_request_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s app_private.poortenboek_sessions; c app_private.poortenboek_codes; team uuid; old_hash text; body_hash text;
  e app_private.poortenboek_elections; choices uuid[]; expected_round text; guide app_private.poortenboek_tutorials; step integer; chapter_no integer;
begin
  if _action in ('tutorial','chapter_read') then
    s:=app_private.poortenboek_session(_token_hash);
    select * into c from app_private.poortenboek_codes where id=s.code_id;
    if _action='tutorial' then
      step:=(_payload->>'step')::integer;
      if (_payload->>'version')::integer is distinct from 1 or step is null or step not between 0 and 8 then raise exception 'INVALID_INPUT'; end if;
      insert into app_private.poortenboek_tutorials(event_id,child_id) values(c.event_id,c.child_id) on conflict do nothing;
      select * into guide from app_private.poortenboek_tutorials where event_id=c.event_id and child_id=c.child_id and version=1 for update;
      if step>guide.furthest_step+1 or (coalesce((_payload->>'completed')::boolean,false) and (step<>8 or guide.furthest_step<8)) then raise exception 'TUTORIAL_STEP_REQUIRED'; end if;
      update app_private.poortenboek_tutorials set last_step=step,furthest_step=greatest(furthest_step,step),
        completed_at=case when coalesce((_payload->>'completed')::boolean,false) then coalesce(completed_at,now()) else completed_at end where event_id=c.event_id and child_id=c.child_id and version=1;
    else
      chapter_no:=(_payload->>'chapter')::integer;
      if chapter_no is null or not exists(select 1 from app_private.poortenboek_story_chapters where event_id=c.event_id and child_id=c.child_id and chapter=chapter_no)
        or (chapter_no=6 and not exists(select 1 from app_private.poortenboek_passport_seals where event_id=c.event_id and child_id=c.child_id and finale)) then raise exception 'CHAPTER_LOCKED'; end if;
      insert into app_private.poortenboek_chapter_reads(event_id,child_id,chapter) values(c.event_id,c.child_id,chapter_no) on conflict do nothing;
    end if;
    return app_private.poortenboek_snapshot(s);
  end if;
  if _action not in ('identity','practice','banner_vote','vote') then
    return api.poortenboek_child_action_v1(_token_hash,_action,_payload,_request_id);
  end if;
  s:=app_private.poortenboek_session(_token_hash);
  select * into c from app_private.poortenboek_codes where id=s.code_id;
  team:=app_private.poortenboek_team(c.event_id,c.child_id);
  if _request_id is null then raise exception 'INVALID_INPUT'; end if;
  body_hash:=md5(jsonb_build_array(_action,_payload)::text);
  select commands.body_hash into old_hash from app_private.poortenboek_commands commands where session_id=s.id and request_id=_request_id;
  if old_hash is not null then
    if old_hash<>body_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return app_private.poortenboek_snapshot(s);
  end if;
  if _action='vote' then
    e:=app_private.poortenboek_election(c.event_id,team); e:=app_private.poortenboek_advance(e.id);
    expected_round:=_payload->>'round';
    if (_payload->>'electionId')::uuid is distinct from e.id or expected_round is distinct from e.phase or e.phase='finished'
      or now()>=(case when e.phase='round_one' then e.round_one_deadline else e.round_two_deadline end) then raise exception 'VOTING_CLOSED'; end if;
    select array_agg(value::uuid) into choices from jsonb_array_elements_text(_payload->'choices');
    if coalesce(cardinality(choices),0)<1 or cardinality(choices)>(case when e.phase='round_one' then 3 else 1 end)
      or cardinality(choices)<>(select count(distinct id) from unnest(choices) id)
      or exists(select 1 from unnest(choices) choice(option_id) where not exists(select 1 from app_private.poortenboek_name_options o where o.id=choice.option_id and o.event_id=c.event_id and o.active))
      or not choices<@(case when e.phase='round_two' then e.finalists else e.option_ids end) then raise exception 'INVALID_OPTIONS'; end if;
    insert into app_private.poortenboek_ballots(election_id,child_id,round,choices) values(e.id,c.child_id,e.phase,choices)
      on conflict(election_id,child_id,round) do update set choices=excluded.choices,updated_at=now();
    perform app_private.poortenboek_advance(e.id);
  elsif _action='identity' then
    if (_payload->>'avatarId') not in ('nightwatcher','little-wizard','ghost-scout','pumpkin-guardian','shadow-traveler','moon-knight')
      or (_payload->>'lanternShape') not in ('classic','moon','tower','crystal')
      or (_payload->>'lanternColor') not in ('amber','cyan','violet','emerald','rose','moonlight') then raise exception 'INVALID_INPUT'; end if;
    insert into app_private.poortenboek_child_identity(event_id,child_id,avatar_id,lantern_shape,lantern_color)
      values(c.event_id,c.child_id,_payload->>'avatarId',_payload->>'lanternShape',_payload->>'lanternColor')
      on conflict(event_id,child_id) do update set avatar_id=excluded.avatar_id,lantern_shape=excluded.lantern_shape,lantern_color=excluded.lantern_color,updated_at=now();
  elsif _action='practice' then
    if (_payload->>'heldMs')::integer<1200 then raise exception 'PRACTICE_HOLD_REQUIRED'; end if;
    insert into app_private.poortenboek_practice(event_id,child_id) values(c.event_id,c.child_id) on conflict do nothing;
  else
    if (select phase in ('live','paused','completed','archived') from app_private.events where id=c.event_id) then raise exception 'BANNER_LOCKED'; end if;
    if not app_private.poortenboek_valid_banner(_payload->'choices') then raise exception 'INVALID_INPUT'; end if;
    insert into app_private.poortenboek_banner_votes(event_id,team_id,child_id,choices)
      values(c.event_id,team,c.child_id,_payload->'choices') on conflict(event_id,team_id,child_id)
      do update set choices=excluded.choices,updated_at=now();
    perform app_private.poortenboek_resolve_banner(c.event_id,team);
  end if;
  insert into app_private.poortenboek_commands(session_id,request_id,body_hash) values(s.id,_request_id,body_hash);
  perform realtime.send(jsonb_build_object('teamId',team),'snapshot_changed','admin-event:'||c.event_id,true);
  return app_private.poortenboek_snapshot(s);
end $$;

create or replace function api.event_public_snapshot (_event_slug text)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
  as $$
  select
    jsonb_build_object('startsAt',(select first_start_at from app_private.event_route_settings where event_id=event.id),'endsAt',(select finale_closes_at from app_private.event_route_settings where event_id=event.id),'slug', event.slug, 'title', event.title, 'date', event.local_date, 'timezone', event.timezone, 'phase', event.phase, 'priceCents', event.price_cents, 'currency', event.currency, 'registrationOpen', coalesce((event.settings ->> 'groupRegistrationOpen')::boolean, false)
    and (event.registration_open_at is null
      or event.registration_open_at <= now())
  and (event.registration_close_at is null
    or event.registration_close_at > now()), 'groupRegistrationOpen', coalesce((event.settings ->> 'groupRegistrationOpen')::boolean, false)
and (event.registration_open_at is null
  or event.registration_open_at <= now())
and (event.registration_close_at is null
  or event.registration_close_at > now()), 'portalRegistrationOpen', coalesce((event.settings ->> 'portalRegistrationOpen')::boolean, true), 'worlds', coalesce((
  select
    jsonb_agg(jsonb_build_object('slug', world.slug, 'name', world.name, 'story', world.story, 'artworkPath', world.artwork_path)
  order by world.sort_order)
  from app_private.worlds world
  where
    world.event_id = event.id), '[]'::jsonb), 'sponsors', coalesce((
  select
    jsonb_agg(jsonb_build_object('name', publication.approved_name, 'logoPath', publication.logo_path, 'url', publication.website_url)
    order by publication.sort_order, publication.approved_name)
  from app_private.sponsor_publications publication
  join app_private.sponsor_applications application on application.id = publication.sponsor_application_id
  where
    application.event_id = event.id), '[]'::jsonb), 'content', coalesce((
  select
    jsonb_object_agg(content.page_key, content.structured_content order by content.page_key)
  from app_private.content_versions content
where
  content.event_id = event.id
  and content.locale = 'nl-NL'
  and content.status = 'published'
  and content.content_kind = 'page'), '{}'::jsonb))
  from
    app_private.events event
  where
    event.slug = _event_slug
$$;
