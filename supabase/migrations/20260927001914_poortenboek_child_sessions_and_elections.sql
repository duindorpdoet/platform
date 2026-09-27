begin;

-- Child credentials never become Supabase users or participant authorization tokens.
create table app_private.poortenboek_codes (
  id uuid primary key default gen_random_uuid(), event_id uuid not null references app_private.events(id),
  child_id uuid not null references app_private.children(id),
  code_digest text not null unique check(code_digest ~ '^[a-f0-9]{64}$'),
  ciphertext text not null check(length(ciphertext) between 40 and 500),
  created_at timestamptz not null default now(), revoked_at timestamptz,
  last_used_at timestamptz
);
create unique index poortenboek_one_code on app_private.poortenboek_codes(event_id,child_id) where revoked_at is null;
create index poortenboek_codes_child on app_private.poortenboek_codes(child_id);
create table app_private.poortenboek_sessions (
  id uuid primary key default gen_random_uuid(), code_id uuid not null references app_private.poortenboek_codes(id),
  token_hash text not null unique check(token_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '12 hours',
  revoked_at timestamptz, welcome_seen boolean not null default false,
  check(expires_at=created_at+interval '12 hours')
);
create index poortenboek_sessions_code on app_private.poortenboek_sessions(code_id);
create table app_private.poortenboek_progress (
  event_id uuid not null references app_private.events(id), child_id uuid not null references app_private.children(id),
  checklist boolean[] not null default array[false,false,false,false,false,false] check(cardinality(checklist)=6 and array_position(checklist,null) is null),
  sound_enabled boolean not null default false, updated_at timestamptz not null default now(), primary key(event_id,child_id)
);
create index poortenboek_progress_child on app_private.poortenboek_progress(child_id);
-- Future route events can award per-child entries without a fixed number of gates.
create table app_private.poortenboek_unlocks (
  id uuid primary key default gen_random_uuid(), event_id uuid not null references app_private.events(id),
  child_id uuid not null references app_private.children(id), source_event_id bigint not null references app_private.journey_events(id),
  kind text not null check(kind in('seal','chapter')), world_id uuid references app_private.worlds(id),
  earned_at timestamptz not null default now(), unique(event_id,child_id,source_event_id,kind)
);
create index poortenboek_unlocks_child on app_private.poortenboek_unlocks(child_id);
create index poortenboek_unlocks_world on app_private.poortenboek_unlocks(world_id);
create index poortenboek_unlocks_source on app_private.poortenboek_unlocks(source_event_id);
create table app_private.poortenboek_settings (
  event_id uuid primary key references app_private.events(id), round_one_deadline timestamptz not null,
  round_two_deadline timestamptz not null, closes_at timestamptz not null,
  check(round_one_deadline<round_two_deadline and round_two_deadline<=closes_at)
);
create table app_private.poortenboek_name_options (
  id uuid primary key default gen_random_uuid(), event_id uuid not null references app_private.events(id),
  label text not null check(length(label) between 2 and 80), active boolean not null default true,
  sort_order integer not null check(sort_order between 0 and 1000), unique(event_id,label)
);
create table app_private.poortenboek_elections (
  id uuid primary key default gen_random_uuid(), event_id uuid not null references app_private.events(id),
  -- Derived from authoritative party membership, or the singleton registration UUID.
  team_id uuid not null, generation integer not null, membership_hash text not null,
  eligible_children uuid[] not null, option_ids uuid[] not null,
  phase text not null check(phase in('direct','round_one','round_two','finished','superseded')),
  round_one_deadline timestamptz not null, round_two_deadline timestamptz not null,
  finalists uuid[] not null default '{}', winner_id uuid references app_private.poortenboek_name_options(id),
  magic_tiebreak boolean not null default false, created_at timestamptz not null default now(),
  unique(event_id,team_id,generation)
);
create unique index poortenboek_current_election on app_private.poortenboek_elections(event_id,team_id) where phase<>'superseded';
create index poortenboek_elections_winner on app_private.poortenboek_elections(winner_id);
create table app_private.poortenboek_ballots (
  election_id uuid not null references app_private.poortenboek_elections(id), child_id uuid not null references app_private.children(id),
  round text not null check(round in('direct','round_one','round_two')), choices uuid[] not null,
  updated_at timestamptz not null default now(), primary key(election_id,child_id,round)
);
create index poortenboek_ballots_child on app_private.poortenboek_ballots(child_id);
create table app_private.poortenboek_commands (
  session_id uuid not null references app_private.poortenboek_sessions(id), request_id uuid not null,
  body_hash text not null, primary key(session_id,request_id)
);
create table app_private.poortenboek_throttles (
  subject_hash text primary key, attempts integer not null, window_started_at timestamptz not null,
  blocked_until timestamptz
);

create function app_private.poortenboek_defaults(_event uuid) returns void language plpgsql set search_path='' as $$
begin
  insert into app_private.poortenboek_settings
    select id,(local_date::timestamp-interval '3 days'+interval '18 hours') at time zone timezone,
      (local_date::timestamp-interval '2 days'+interval '18 hours') at time zone timezone,
      (local_date::timestamp-interval '1 day'+interval '18 hours') at time zone timezone
    from app_private.events where id=_event on conflict do nothing;
  insert into app_private.poortenboek_name_options(event_id,label,sort_order)
    select _event,label,ordinality from unnest(array['De Nachtlopers','De Poortwachters','De Schaduwzoekers','De Maanjagers','De Duinspoken','De Mistlopers','De Fluistervlammen','De Lantaarnbende','De Spookverkenners','De Vleermuiswacht','De Nachtuilen','De Magische Maskers','De Griezelgidsen','De Pompoenpatrouille','De Donderspoken','De Sterrenzoekers','De Geheime Sleutels','De Maanpoortbende','De Snoepspeurders','De Verdwaalde Schaduwen']) with ordinality n(label,ordinality)
    on conflict(event_id,label) do nothing;
end $$;
do $$ declare e uuid; begin for e in select id from app_private.events loop perform app_private.poortenboek_defaults(e); end loop; end $$;

create function app_private.poortenboek_members(_event uuid,_team uuid)
returns table(child_id uuid,registration_id uuid,first_name text) language sql stable set search_path='' as $$
  select c.id,r.id,c.first_name from app_private.registrations r
    join app_private.registration_children rc on rc.registration_id=r.id and rc.event_id=r.event_id and rc.participation_status='active'
    join app_private.children c on c.id=rc.child_id and c.household_id=r.household_id and c.archived_at is null
    left join app_private.together_memberships m on m.registration_id=r.id and m.left_at is null
    where r.event_id=_event and r.status='submitted' and coalesce(m.party_id,r.id)=_team
$$;
create function app_private.poortenboek_team(_event uuid,_child uuid) returns uuid language sql stable set search_path='' as $$
  select coalesce(m.party_id,r.id) from app_private.registrations r
    join app_private.registration_children rc on rc.registration_id=r.id and rc.event_id=r.event_id and rc.participation_status='active'
    join app_private.children c on c.id=rc.child_id and c.household_id=r.household_id and c.archived_at is null
    left join app_private.together_memberships m on m.registration_id=r.id and m.left_at is null
    join app_private.events e on e.id=r.event_id and e.phase<>'archived'
    where rc.child_id=_child and r.event_id=_event and r.status='submitted'
$$;
create function app_private.poortenboek_session(_hash text) returns app_private.poortenboek_sessions language plpgsql set search_path='' as $$
declare s app_private.poortenboek_sessions; c app_private.poortenboek_codes;
begin
  select * into s from app_private.poortenboek_sessions where token_hash=_hash for update;
  select * into c from app_private.poortenboek_codes where id=s.code_id;
  if s.id is null or s.revoked_at is not null or s.expires_at<=clock_timestamp() or c.revoked_at is not null
    or app_private.poortenboek_team(c.event_id,c.child_id) is null then raise exception 'CHILD_SESSION_INVALID' using errcode='42501'; end if;
  return s;
end $$;

create function api.poortenboek_login(_digest text,_token_hash text,_ip_hash text,_device_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c app_private.poortenboek_codes; s app_private.poortenboek_sessions; bucket app_private.poortenboek_throttles;
  subject record; allowed boolean:=true; attempts integer:=0;
begin
  if _digest is null or _token_hash is null or _ip_hash is null or _device_hash is null or _digest !~ '^[a-f0-9]{64}$' or _token_hash !~ '^[a-f0-9]{64}$' or _ip_hash !~ '^[a-f0-9]{64}$' or _device_hash !~ '^[a-f0-9]{64}$' then raise exception 'INVALID_INPUT'; end if;
  -- Persistent, atomic limits. Failed attempts commit: never raise after consuming them.
  for subject in select * from (values('code:'||_digest,12),('ip:'||_ip_hash,60),('device:'||_device_hash,30)) v(key,lim) order by key loop
    insert into app_private.poortenboek_throttles values(subject.key,0,now(),null) on conflict do nothing;
    select * into bucket from app_private.poortenboek_throttles where subject_hash=subject.key for update;
    if bucket.window_started_at<=now()-interval '15 minutes' and coalesce(bucket.blocked_until,now())<=now() then
      bucket.attempts:=0; bucket.window_started_at:=now(); bucket.blocked_until:=null;
    end if;
    bucket.attempts:=least(bucket.attempts+1,10000); attempts:=greatest(attempts,bucket.attempts);
    if bucket.attempts>subject.lim and bucket.blocked_until is null then bucket.blocked_until:=now()+interval '15 minutes'; end if;
    if bucket.blocked_until>now() then allowed:=false; end if;
    update app_private.poortenboek_throttles set attempts=bucket.attempts,window_started_at=bucket.window_started_at,blocked_until=bucket.blocked_until where subject_hash=subject.key;
  end loop;
  select * into c from app_private.poortenboek_codes where code_digest=_digest and revoked_at is null for update;
  if not allowed or c.id is null or app_private.poortenboek_team(c.event_id,c.child_id) is null then
    insert into app_private.audit_events(action,resource_type,minimal_change) values('poortenboek.login_failed','poortenboek',jsonb_build_object('limited',not allowed));
    return jsonb_build_object('ok',false,'delayMs',case when attempts>=3 then 650 else 250 end);
  end if;
  insert into app_private.poortenboek_sessions(code_id,token_hash) values(c.id,_token_hash) returning * into s;
  update app_private.poortenboek_codes set last_used_at=date_trunc('minute',now()) where id=c.id;
  insert into app_private.audit_events(event_id,action,resource_type,resource_id,minimal_change)
    values(c.event_id,'poortenboek.login','child',c.child_id,'{}');
  return jsonb_build_object('ok',true,'expiresAt',s.expires_at);
end $$;

create function app_private.poortenboek_election(_event uuid,_team uuid) returns app_private.poortenboek_elections
language plpgsql set search_path='' as $$
declare e app_private.poortenboek_elections; settings app_private.poortenboek_settings; members uuid[]; fingerprint text; next_generation integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('poortenboek:'||_team::text,0));
  perform app_private.poortenboek_defaults(_event);
  select array_agg(child_id order by child_id) into members from app_private.poortenboek_members(_event,_team);
  if coalesce(cardinality(members),0)=0 then raise exception 'NO_TEAM'; end if;
  fingerprint:=md5(members::text);
  select * into e from app_private.poortenboek_elections where event_id=_event and team_id=_team and phase<>'superseded' for update;
  if e.id is not null and e.membership_hash<>fingerprint then
    update app_private.poortenboek_elections set phase='superseded' where id=e.id; e.id:=null;
  end if;
  if e.id is null then
    select * into settings from app_private.poortenboek_settings where event_id=_event;
    select coalesce(max(generation),0)+1 into next_generation from app_private.poortenboek_elections where event_id=_event and team_id=_team;
    insert into app_private.poortenboek_elections(event_id,team_id,generation,membership_hash,eligible_children,option_ids,phase,round_one_deadline,round_two_deadline)
      values(_event,_team,next_generation,fingerprint,members,
        (select array_agg(id order by sort_order,id) from app_private.poortenboek_name_options where event_id=_event and active),
        case when cardinality(members)=1 then 'direct' else 'round_one' end,settings.round_one_deadline,settings.round_two_deadline) returning * into e;
  end if;
  return e;
end $$;
create function app_private.poortenboek_scores(_election uuid)
returns table(option_id uuid,sparks bigint,final_votes bigint) language sql stable set search_path='' as $$
  select opt.id,
    coalesce((select sum(4-choice.rank) from app_private.poortenboek_ballots b,
      unnest(b.choices) with ordinality choice(id,rank) where b.election_id=e.id and b.round='round_one' and choice.id=opt.id),0)::bigint,
    (select count(*) from app_private.poortenboek_ballots b where b.election_id=e.id and b.round in('round_two','direct') and b.choices[1]=opt.id)
  from app_private.poortenboek_elections e join app_private.poortenboek_name_options opt on opt.id=any(e.option_ids) where e.id=_election
$$;
create function app_private.poortenboek_advance(_id uuid) returns app_private.poortenboek_elections language plpgsql set search_path='' as $$
declare e app_private.poortenboek_elections; votes integer; ids uuid[]; winner uuid; tied integer;
begin
  select * into e from app_private.poortenboek_elections where id=_id for update;
  select count(*) into votes from app_private.poortenboek_ballots where election_id=e.id and round=e.phase;
  if e.phase='round_one' and (votes=cardinality(e.eligible_children) or now()>=e.round_one_deadline) then
    select array_agg(option_id order by sparks desc,tie) into ids from (
      select option_id,sparks,md5(e.event_id::text||e.team_id::text||option_id::text) tie
      from app_private.poortenboek_scores(e.id) order by sparks desc,tie limit 3) ranked;
    update app_private.poortenboek_elections set phase='round_two',finalists=ids where id=e.id returning * into e;
    select count(*) into votes from app_private.poortenboek_ballots where election_id=e.id and round='round_two';
  end if;
  if e.phase in('round_two','direct') and (votes=cardinality(e.eligible_children) or now()>=e.round_two_deadline) then
    -- No ballots means no manufactured name: the election stays visibly unnamed.
    if exists(select 1 from app_private.poortenboek_ballots where election_id=e.id) then
      select option_id into winner from app_private.poortenboek_scores(e.id)
        where e.phase='direct' or option_id=any(e.finalists)
        order by final_votes desc,sparks desc,md5(e.event_id::text||e.team_id::text||option_id::text) limit 1;
      select count(*) into tied from app_private.poortenboek_scores(e.id) s
        where (e.phase='direct' or s.option_id=any(e.finalists))
          and s.final_votes=(select final_votes from app_private.poortenboek_scores(e.id) where option_id=winner)
          and s.sparks=(select sparks from app_private.poortenboek_scores(e.id) where option_id=winner);
      update app_private.poortenboek_elections set phase='finished',winner_id=winner,magic_tiebreak=tied>1 where id=e.id returning * into e;
    end if;
  end if;
  return e;
end $$;

create function app_private.poortenboek_snapshot(_session app_private.poortenboek_sessions) returns jsonb language plpgsql set search_path='' as $$
declare c app_private.poortenboek_codes; team uuid; election app_private.poortenboek_elections; progress app_private.poortenboek_progress;
begin
  select * into c from app_private.poortenboek_codes where id=_session.code_id;
  team:=app_private.poortenboek_team(c.event_id,c.child_id);
  election:=app_private.poortenboek_election(c.event_id,team);
  election:=app_private.poortenboek_advance(election.id);
  insert into app_private.poortenboek_progress(event_id,child_id) values(c.event_id,c.child_id) on conflict do nothing;
  select * into progress from app_private.poortenboek_progress where event_id=c.event_id and child_id=c.child_id;
  return jsonb_build_object('firstName',(select first_name from app_private.children where id=c.child_id),
    'medallion',get_byte(extensions.digest(c.child_id::text,'sha256'),0)%6,
    'expiresAt',_session.expires_at,'welcomeRequired',not _session.welcome_seen,'demo',false,
    'eventDate',(select local_date from app_private.events where id=c.event_id),
    'eventPhase',(select phase from app_private.events where id=c.event_id),
    'checklist',to_jsonb(progress.checklist),'soundEnabled',progress.sound_enabled,
    'companions',(select jsonb_agg(jsonb_build_object('firstName',m.first_name,
      'medallion',get_byte(extensions.digest(m.child_id::text,'sha256'),0)%6,
      'status',case when exists(select 1 from app_private.group_registrations a join app_private.group_runs run on run.group_id=a.group_id where a.registration_id=m.registration_id and a.superseded_at is null and run.status='completed') then 'completed'
        when exists(select 1 from app_private.group_registrations a join app_private.group_runs run on run.group_id=a.group_id where a.registration_id=m.registration_id and a.superseded_at is null and run.status='live') then 'underway'
        when p.checklist=array[true,true,true,true,true,true] then 'ready' else 'preparing' end) order by m.first_name,m.child_id)
      from app_private.poortenboek_members(c.event_id,team) m left join app_private.poortenboek_progress p on p.event_id=c.event_id and p.child_id=m.child_id),
    'election',jsonb_build_object('id',election.id,'phase',election.phase,'generation',election.generation,
      'eligibleCount',cardinality(election.eligible_children),'votedCount',(select count(*) from app_private.poortenboek_ballots where election_id=election.id and round=case when election.phase='finished' then case when cardinality(election.eligible_children)=1 then 'direct' else 'round_two' end else election.phase end),
      'options',(select jsonb_agg(jsonb_build_object('id',id,'label',label) order by sort_order,id) from app_private.poortenboek_name_options where id=any(case when election.phase='round_two' then election.finalists else election.option_ids end)),
      'ownChoices',coalesce((select to_jsonb(choices) from app_private.poortenboek_ballots where election_id=election.id and child_id=c.child_id and round=election.phase),'[]'),
      'winner',(select label from app_private.poortenboek_name_options where id=election.winner_id),
      'magicTiebreak',election.magic_tiebreak,'deadline',case when election.phase='round_one' then election.round_one_deadline else election.round_two_deadline end,
      'open',election.phase<>'finished' and now()<case when election.phase='round_one' then election.round_one_deadline else election.round_two_deadline end),
    'start',(select jsonb_build_object('name',point.name,'startsAt',slot.starts_at)
      from app_private.registration_children rc join app_private.group_registrations a on a.registration_id=rc.registration_id and a.superseded_at is null and a.published_at is not null
      join app_private.group_schedule_revisions schedule on schedule.group_id=a.group_id and schedule.state='published'
      join app_private.start_slots slot on slot.id=schedule.start_slot_id join app_private.start_points point on point.id=slot.start_point_id
      where rc.child_id=c.child_id and rc.event_id=c.event_id and rc.participation_status='active' order by schedule.revision desc limit 1),
    'worlds',coalesce((select jsonb_agg(jsonb_build_object('slug',slug,'name',name,'story',story) order by sort_order) from app_private.worlds where event_id=c.event_id),'[]'),
    'unlocks',coalesce((select jsonb_agg(jsonb_build_object('kind',u.kind,'world',w.name,'earnedAt',u.earned_at) order by u.earned_at) from app_private.poortenboek_unlocks u left join app_private.worlds w on w.id=u.world_id where u.event_id=c.event_id and u.child_id=c.child_id),'[]'),
    'updatedAt',clock_timestamp());
end $$;

create function api.poortenboek_child_action(_token_hash text,_action text,_payload jsonb default '{}',_request_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s app_private.poortenboek_sessions; c app_private.poortenboek_codes; e app_private.poortenboek_elections; team uuid;
  choices uuid[]; expected_round text; old_hash text; body_hash text;
begin
  -- Event first agrees with organizer merges; session/code validation never refreshes expiry.
  perform event_record.id from app_private.events event_record join app_private.poortenboek_codes code on code.event_id=event_record.id
    join app_private.poortenboek_sessions session on session.code_id=code.id where session.token_hash=_token_hash for share of event_record;
  s:=app_private.poortenboek_session(_token_hash);
  select * into c from app_private.poortenboek_codes where id=s.code_id;
  if _action='logout' then update app_private.poortenboek_sessions set revoked_at=now() where id=s.id; return '{}'::jsonb; end if;
  if _action='welcome' then update app_private.poortenboek_sessions set welcome_seen=true where id=s.id returning * into s;
  elsif _action='checklist' then
    if jsonb_typeof(_payload->'values') is distinct from 'array' or jsonb_array_length(_payload->'values')<>6
      or exists(select 1 from jsonb_array_elements(_payload->'values') v where jsonb_typeof(v)<>'boolean') then raise exception 'INVALID_INPUT'; end if;
    insert into app_private.poortenboek_progress(event_id,child_id,checklist) values(c.event_id,c.child_id,array(select value::text::boolean from jsonb_array_elements(_payload->'values')))
      on conflict(event_id,child_id) do update set checklist=excluded.checklist,updated_at=now();
  elsif _action='sound' then
    if jsonb_typeof(_payload->'enabled') is distinct from 'boolean' then raise exception 'INVALID_INPUT'; end if;
    insert into app_private.poortenboek_progress(event_id,child_id,sound_enabled) values(c.event_id,c.child_id,(_payload->>'enabled')::boolean)
      on conflict(event_id,child_id) do update set sound_enabled=excluded.sound_enabled,updated_at=now();
  elsif _action='vote' then
    if _request_id is null then raise exception 'INVALID_INPUT'; end if;
    body_hash:=md5(_payload::text);
    select commands.body_hash into old_hash from app_private.poortenboek_commands commands where session_id=s.id and request_id=_request_id;
    if old_hash is not null then
      if old_hash<>body_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      return app_private.poortenboek_snapshot(s);
    end if;
    team:=app_private.poortenboek_team(c.event_id,c.child_id);
    e:=app_private.poortenboek_election(c.event_id,team); e:=app_private.poortenboek_advance(e.id);
    expected_round:=_payload->>'round';
    if (_payload->>'electionId')::uuid is distinct from e.id or expected_round is distinct from e.phase or e.phase='finished'
      or now()>=(case when e.phase='round_one' then e.round_one_deadline else e.round_two_deadline end) then raise exception 'VOTING_CLOSED'; end if;
    select array_agg(value::uuid) into choices from jsonb_array_elements_text(_payload->'choices');
    if coalesce(cardinality(choices),0)<>(case when e.phase='round_one' then 3 else 1 end)
      or cardinality(choices)<>(select count(distinct id) from unnest(choices) id)
      or exists(select 1 from unnest(choices) choice(option_id) where not exists(select 1 from app_private.poortenboek_name_options o where o.id=choice.option_id and o.event_id=c.event_id and o.active))
      or not choices<@(case when e.phase='round_two' then e.finalists else e.option_ids end) then raise exception 'INVALID_OPTIONS'; end if;
    insert into app_private.poortenboek_ballots(election_id,child_id,round,choices) values(e.id,c.child_id,e.phase,choices)
      on conflict(election_id,child_id,round) do update set choices=excluded.choices,updated_at=now();
    insert into app_private.poortenboek_commands values(s.id,_request_id,body_hash);
  elsif _action<>'snapshot' then raise exception 'INVALID_INPUT'; end if;
  return app_private.poortenboek_snapshot(s);
end $$;

-- Keep the identity and eligibility of options used by an election immutable.
create function app_private.poortenboek_protect_option() returns trigger language plpgsql set search_path='' as $$
begin
  if exists(select 1 from app_private.poortenboek_elections where old.id=any(option_ids)) then
    if tg_op='DELETE' then raise exception 'OPTION_IN_USE'; end if;
    if new.label is distinct from old.label or new.event_id is distinct from old.event_id
      or new.id is distinct from old.id or (old.active and not new.active) then raise exception 'OPTION_IN_USE'; end if;
  end if;
  if tg_op='DELETE' then return old; end if; return new;
end $$;
create trigger poortenboek_option_immutable before update or delete on app_private.poortenboek_name_options
  for each row execute function app_private.poortenboek_protect_option();

create function app_private.poortenboek_reset(_event uuid,_team uuid) returns void language plpgsql set search_path='' as $$
declare e app_private.poortenboek_elections; closing timestamptz;
begin
  select closes_at into closing from app_private.poortenboek_settings where event_id=_event;
  if closing is null or now()>=closing then raise exception 'ELECTION_LOCKED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('poortenboek:'||_team::text,0));
  update app_private.poortenboek_elections set phase='superseded' where event_id=_event and team_id=_team and phase<>'superseded';
  e:=app_private.poortenboek_election(_event,_team);
  -- A deliberate reset after the ordinary deadline divides the remaining time
  -- between both rounds, without extending the organizational final close.
  if e.round_one_deadline<=now() then
    update app_private.poortenboek_elections set round_one_deadline=now()+(closing-now())/2,
      round_two_deadline=closing where id=e.id;
  end if;
end $$;

create function app_private.poortenboek_parent_child(_actor uuid,_event uuid,_child uuid) returns void language plpgsql stable set search_path='' as $$
begin
  if _actor is null or not exists(select 1 from app_private.children c
    join app_private.household_members hm on hm.household_id=c.household_id and hm.user_id=_actor and hm.relation_role='owner' and hm.revoked_at is null
    join app_private.registration_children rc on rc.child_id=c.id and rc.event_id=_event and rc.participation_status='active'
    join app_private.registrations r on r.id=rc.registration_id and r.household_id=c.household_id and r.status='submitted'
    where c.id=_child and c.archived_at is null) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
end $$;
create function api.poortenboek_parent(_actor uuid,_event_slug text,_action text,_child_id uuid default null,_digest text default null,_ciphertext text default null,_reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_event uuid; code app_private.poortenboek_codes; team uuid; settings app_private.poortenboek_settings;
begin
  select id into v_event from app_private.events where slug=_event_slug and phase<>'archived' for share;
  if _actor is null or v_event is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if _action='list' then
    return coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'firstName',c.first_name,
      'activeSessions',(select count(*) from app_private.poortenboek_sessions s join app_private.poortenboek_codes credential on credential.id=s.code_id where credential.child_id=c.id and credential.event_id=v_event and credential.revoked_at is null and s.revoked_at is null and s.expires_at>now()),
      'lastUsedAt',(select max(last_used_at) from app_private.poortenboek_codes credential where credential.child_id=c.id and credential.event_id=v_event),
      'together',(select count(*)>1 from app_private.poortenboek_members(v_event,app_private.poortenboek_team(v_event,c.id)) m where m.registration_id<>rc.registration_id or m.child_id=c.id)) order by c.first_name,c.id)
      from app_private.children c join app_private.household_members hm on hm.household_id=c.household_id and hm.user_id=_actor and hm.relation_role='owner' and hm.revoked_at is null
      join app_private.registration_children rc on rc.child_id=c.id and rc.event_id=v_event and rc.participation_status='active'
      join app_private.registrations r on r.id=rc.registration_id and r.status='submitted' where c.archived_at is null),'[]');
  end if;
  perform app_private.poortenboek_parent_child(_actor,v_event,_child_id);
  perform pg_advisory_xact_lock(hashtextextended('poortenboek-code:'||v_event::text||_child_id::text,0));
  select * into code from app_private.poortenboek_codes c where c.event_id=v_event and c.child_id=_child_id and c.revoked_at is null for update;
  if _action in('view','renew') then
    if _action='renew' or code.id is null then
      if _digest is null or _ciphertext is null then return jsonb_build_object('needsCode',true,'eventId',v_event); end if;
      if _action='renew' then
        update app_private.poortenboek_codes c set revoked_at=now() where c.event_id=v_event and c.child_id=_child_id and revoked_at is null;
        update app_private.poortenboek_sessions s set revoked_at=now() from app_private.poortenboek_codes c where c.id=s.code_id and c.event_id=v_event and c.child_id=_child_id and s.revoked_at is null;
      end if;
      insert into app_private.poortenboek_codes(event_id,child_id,code_digest,ciphertext) values(v_event,_child_id,_digest,_ciphertext) returning * into code;
      insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
        values(v_event,_actor,case when _action='renew' then 'poortenboek.code_renewed' else 'poortenboek.code_created' end,'child',_child_id,'{}');
    end if;
    return jsonb_build_object('eventId',v_event,'ciphertext',code.ciphertext);
  elsif _action='revoke' then
    update app_private.poortenboek_sessions s set revoked_at=now() from app_private.poortenboek_codes c where c.id=s.code_id and c.event_id=v_event and c.child_id=_child_id and s.revoked_at is null;
    insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(v_event,_actor,'poortenboek.sessions_revoked','child',_child_id,'{}');
  elsif _action='reset' then
    if length(trim(coalesce(_reason,''))) not between 10 and 500 then raise exception 'REASON_REQUIRED'; end if;
    perform app_private.poortenboek_defaults(v_event); select * into settings from app_private.poortenboek_settings s where s.event_id=v_event;
    if now()>=settings.closes_at then raise exception 'ELECTION_LOCKED'; end if;
    team:=app_private.poortenboek_team(v_event,_child_id);
    perform app_private.poortenboek_reset(v_event,team);
    insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(v_event,_actor,'poortenboek.election_reset','together_party',team,jsonb_build_object('reason',trim(_reason)));
  else raise exception 'INVALID_INPUT'; end if;
  return '{}'::jsonb;
end $$;

create function api.poortenboek_admin(_actor uuid,_event_slug text,_action text,_payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare ev uuid; settings app_private.poortenboek_settings; opt record; team uuid;
begin
  select id into ev from app_private.events where slug=_event_slug for update;
  if _actor is null or ev is null or not(app_private.has_capability(ev,'event_admin',_actor) or app_private.has_capability(ev,'groups_manage',_actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform app_private.poortenboek_defaults(ev);
  select * into settings from app_private.poortenboek_settings where event_id=ev;
  if _action='save' then
    if now()>=settings.closes_at then raise exception 'ELECTION_LOCKED'; end if;
    for opt in select * from jsonb_to_recordset(_payload->'options') as o(id uuid,active boolean,"sortOrder" integer) loop
      if opt.active=false and exists(select 1 from app_private.poortenboek_elections e where e.event_id=ev and opt.id=any(e.option_ids)) then raise exception 'OPTION_IN_USE'; end if;
      update app_private.poortenboek_name_options set active=opt.active,sort_order=opt."sortOrder" where id=opt.id and event_id=ev;
    end loop;
    if (select count(*) from app_private.poortenboek_name_options where event_id=ev and active)<3 then raise exception 'AT_LEAST_THREE_OPTIONS'; end if;
    update app_private.poortenboek_settings set round_one_deadline=(_payload->>'roundOneDeadline')::timestamptz,
      round_two_deadline=(_payload->>'roundTwoDeadline')::timestamptz,closes_at=(_payload->>'closesAt')::timestamptz where event_id=ev;
    -- Open elections follow explicitly configured deadlines; finished results stay fixed.
    update app_private.poortenboek_elections e set round_one_deadline=s.round_one_deadline,round_two_deadline=s.round_two_deadline
      from app_private.poortenboek_settings s where s.event_id=ev and e.event_id=ev and e.phase in('direct','round_one','round_two');
    insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(ev,_actor,'poortenboek.settings_updated','event',ev,'{}');
  elsif _action='reset' then
    if now()>=settings.closes_at or length(trim(coalesce(_payload->>'reason',''))) not between 10 and 500 then raise exception 'ELECTION_LOCKED'; end if;
    team:=(_payload->>'teamId')::uuid;
    perform app_private.poortenboek_reset(ev,team);
    insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change) values(ev,_actor,'poortenboek.election_reset','together_party',team,jsonb_build_object('reason',trim(_payload->>'reason')));
  elsif _action<>'snapshot' then raise exception 'INVALID_INPUT'; end if;
  select * into settings from app_private.poortenboek_settings where event_id=ev;
  return jsonb_build_object('roundOneDeadline',settings.round_one_deadline,'roundTwoDeadline',settings.round_two_deadline,'closesAt',settings.closes_at,
    'options',(select jsonb_agg(jsonb_build_object('id',id,'label',label,'active',active,'sortOrder',sort_order,
      'inUse',exists(select 1 from app_private.poortenboek_elections e where e.event_id=ev and o.id=any(e.option_ids))) order by sort_order,id) from app_private.poortenboek_name_options o where event_id=ev),
    'elections',coalesce((select jsonb_agg(jsonb_build_object('teamId',team_id,'phase',phase,'memberCount',cardinality(eligible_children),'winner',(select label from app_private.poortenboek_name_options where id=e.winner_id)))
      from app_private.poortenboek_elections e where event_id=ev and phase<>'superseded'),'[]'));
end $$;

-- Defense in depth: nothing is selectable by a browser role, including ciphertext.
do $$ declare t text; f record; begin
  for t in select tablename from pg_tables where schemaname='app_private' and tablename like 'poortenboek_%' loop
    execute format('alter table app_private.%I enable row level security',t);
    execute format('revoke all on app_private.%I from public,anon,authenticated',t);
  end loop;
  for f in select p.oid::regprocedure signature,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('api','app_private') and p.proname like 'poortenboek_%' loop
    execute format('revoke all on function %s from public,anon,authenticated',f.signature);
    if f.nspname='api' then execute format('grant execute on function %s to service_role',f.signature); end if;
  end loop;
end $$;
select pg_notify('pgrst','reload schema');
commit;
