begin;

-- Poortenboek V2 is additive. Child access remains exclusively available through
-- the server-side, hashed child session contract introduced in the V1 migration.
create table app_private.poortenboek_child_identity (
  event_id uuid not null references app_private.events(id) on delete cascade,
  child_id uuid not null references app_private.children(id) on delete cascade,
  avatar_id text not null default 'nightwatcher' check (avatar_id in
    ('nightwatcher','little-wizard','ghost-scout','pumpkin-guardian','shadow-traveler','moon-knight')),
  lantern_shape text not null default 'classic' check (lantern_shape in ('classic','moon','tower','crystal')),
  lantern_color text not null default 'amber' check (lantern_color in ('amber','cyan','violet','emerald','rose','moonlight')),
  updated_at timestamptz not null default now(),
  primary key(event_id, child_id)
);

create table app_private.poortenboek_practice (
  event_id uuid not null references app_private.events(id) on delete cascade,
  child_id uuid not null references app_private.children(id) on delete cascade,
  completed_at timestamptz not null default now(),
  primary key(event_id, child_id)
);

create table app_private.poortenboek_banner_votes (
  event_id uuid not null references app_private.events(id) on delete cascade,
  team_id uuid not null,
  child_id uuid not null references app_private.children(id) on delete cascade,
  choices jsonb not null check (
    jsonb_typeof(choices)='object'
    and choices ?& array['shape','color','secondaryColor','border','symbol','lantern','glow']
  ),
  updated_at timestamptz not null default now(),
  primary key(event_id, team_id, child_id)
);
create index poortenboek_banner_votes_child on app_private.poortenboek_banner_votes(child_id);

create table app_private.poortenboek_team_customizations (
  event_id uuid not null references app_private.events(id) on delete cascade,
  team_id uuid not null,
  banner jsonb,
  decided_at timestamptz,
  locked_at timestamptz,
  reset_count integer not null default 0 check(reset_count between 0 and 1),
  updated_at timestamptz not null default now(),
  primary key(event_id, team_id),
  check((banner is null)=(decided_at is null))
);

create table app_private.portal_presentations (
  id uuid primary key default gen_random_uuid(),
  portal_id uuid not null references app_private.portals(id) on delete cascade,
  version integer not null check(version > 0),
  status text not null default 'draft' check(status in ('draft','submitted','approved','changes_requested','rejected','active','retired')),
  world_id uuid not null references app_private.worlds(id) on delete restrict,
  public_name text not null check(char_length(trim(public_name)) between 2 and 120),
  short_description text not null check(char_length(trim(short_description)) between 10 and 500),
  story_fragment text not null check(char_length(trim(story_fragment)) between 10 and 1200),
  symbol text not null check(symbol in ('gate','moon','flame','ghost','key','star','bat','pumpkin')),
  color text not null check(color in ('amber','cyan','violet','emerald','crimson','moonlight')),
  image_path text check(image_path is null or image_path ~ '^/images/[A-Za-z0-9_./-]+[.]webp$'),
  accessibility text not null default 'Geen extra informatie opgegeven' check(char_length(trim(accessibility)) between 2 and 300),
  intensity smallint not null default 2 check(intensity between 1 and 4),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_note text check(review_note is null or char_length(trim(review_note)) between 5 and 500),
  activated_at timestamptz,
  unique(portal_id, version)
);
create unique index portal_presentations_one_active on app_private.portal_presentations(portal_id) where status='active';
create index portal_presentations_review on app_private.portal_presentations(status, submitted_at);

create function app_private.portal_presentation_immutable() returns trigger
language plpgsql set search_path='' as $$
begin
  if old.status in ('approved','active','retired') and
    (new.portal_id,new.version,new.world_id,new.public_name,new.short_description,new.story_fragment,new.symbol,new.color,new.image_path,new.accessibility,new.intensity)
      is distinct from
    (old.portal_id,old.version,old.world_id,old.public_name,old.short_description,old.story_fragment,old.symbol,old.color,old.image_path,old.accessibility,old.intensity)
  then raise exception 'PRESENTATION_IMMUTABLE'; end if;
  return new;
end $$;
create trigger portal_presentation_immutable before update on app_private.portal_presentations
for each row execute function app_private.portal_presentation_immutable();

create table app_private.poortenboek_team_progress (
  event_id uuid not null references app_private.events(id) on delete cascade,
  team_id uuid not null,
  run_id uuid not null references app_private.group_runs(id) on delete restrict,
  run_stop_id uuid not null references app_private.run_stops(id) on delete restrict,
  portal_id uuid not null references app_private.portals(id) on delete restrict,
  world_id uuid not null references app_private.worlds(id) on delete restrict,
  completed_at timestamptz not null,
  finale boolean not null default false,
  primary key(event_id, team_id, run_stop_id)
);
create index poortenboek_team_progress_team on app_private.poortenboek_team_progress(event_id,team_id,completed_at);

create table app_private.poortenboek_passport_seals (
  event_id uuid not null references app_private.events(id) on delete cascade,
  child_id uuid not null references app_private.children(id) on delete cascade,
  team_id uuid not null,
  run_id uuid not null references app_private.group_runs(id) on delete restrict,
  run_stop_id uuid not null references app_private.run_stops(id) on delete restrict,
  portal_id uuid not null references app_private.portals(id) on delete restrict,
  world_id uuid not null references app_private.worlds(id) on delete restrict,
  presentation_id uuid references app_private.portal_presentations(id) on delete restrict,
  presentation_snapshot jsonb not null,
  earned_at timestamptz not null,
  finale boolean not null default false,
  primary key(event_id, child_id, run_stop_id)
);
create index poortenboek_passport_seals_child on app_private.poortenboek_passport_seals(event_id,child_id,earned_at);

create table app_private.poortenboek_story_chapters (
  event_id uuid not null references app_private.events(id) on delete cascade,
  child_id uuid not null references app_private.children(id) on delete cascade,
  chapter smallint not null check(chapter between 1 and 6),
  source_run_id uuid references app_private.group_runs(id) on delete restrict,
  source_stop_id uuid references app_private.run_stops(id) on delete restrict,
  unlocked_at timestamptz not null default now(),
  primary key(event_id,child_id,chapter)
);

create table app_private.portal_incidents (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  portal_id uuid not null references app_private.portals(id) on delete cascade,
  category text not null check(category in ('crowding','lingering','technical','nuisance','unsafe','contact_requested','other')),
  urgency text not null default 'normal' check(urgency in ('normal','high')),
  status text not null default 'new' check(status in ('new','seen','in_progress','resolved','closed')),
  description text not null check(char_length(trim(description)) between 10 and 1000),
  callback_requested boolean not null default false,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_by uuid references auth.users(id),
  resolved_at timestamptz,
  assigned_to uuid references auth.users(id),
  admin_note text check(admin_note is null or char_length(trim(admin_note)) between 2 and 1000),
  resolution_message text check(resolution_message is null or char_length(trim(resolution_message)) between 2 and 1000)
);
create index portal_incidents_live on app_private.portal_incidents(event_id,status,urgency,created_at desc);
create table app_private.portal_incident_history (
  id bigint generated always as identity primary key,
  incident_id uuid not null references app_private.portal_incidents(id) on delete cascade,
  status text not null check(status in ('new','seen','in_progress','resolved','closed')),
  actor_id uuid not null references auth.users(id),
  note text check(note is null or char_length(trim(note)) between 2 and 1000),
  created_at timestamptz not null default now()
);

create table app_private.portal_simulation_runs (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  portal_id uuid not null references app_private.portals(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  state text not null default 'running' check(state in ('running','completed','reset')),
  phase text not null default 'quiet' check(phase in ('quiet','open','approaching','arrived','busy','paused','stopped','incident','chat','seal','finale','completed')),
  scenario jsonb not null default '{"queue":[{"groupCode":"SIM-01","children":8,"etaMinutes":12},{"groupCode":"SIM-02","children":6,"etaMinutes":24}],"visits":0,"children":0,"incident":false,"chatTested":false,"sealTested":false,"finaleTested":false}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  reset_at timestamptz
);
create unique index portal_simulation_one_active on app_private.portal_simulation_runs(portal_id) where state='running';

create table app_private.portal_simulation_events (
  id bigint generated always as identity primary key,
  simulation_run_id uuid not null references app_private.portal_simulation_runs(id) on delete cascade,
  phase text not null check(phase in ('quiet','open','approaching','arrived','busy','paused','stopped','incident','chat','seal','finale','completed')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

-- Explicit role names while retaining legacy rows and contracts.
alter table app_private.portal_owners drop constraint if exists portal_owners_role_check;
alter table app_private.portal_owners add constraint portal_owners_role_check check
  (role in ('owner','portal_manager','actor','reception','tech','viewer','coadmin','crew'));
alter table app_private.portal_owners add column access_level text not null default 'live'
  check(access_level in ('read','live','manage'));
alter table app_private.portal_owners add column suspended_at timestamptz;
update app_private.portal_owners set access_level=case when role in ('owner','coadmin') then 'manage' when role='viewer' then 'read' else 'live' end;
alter table app_private.portal_team_invites drop constraint if exists portal_team_invites_role_check;
alter table app_private.portal_team_invites add constraint portal_team_invites_role_check check
  (role in ('portal_manager','actor','reception','tech','viewer','coadmin','crew'));
alter table app_private.portal_team_invites add column access_level text not null default 'read'
  check(access_level in ('read','live','manage'));
update app_private.portal_team_invites set access_level=case when role='coadmin' then 'manage' when role='viewer' then 'read' else 'live' end;

create function app_private.poortkamer_sync_access_level() returns trigger
language plpgsql set search_path='' as $$
begin
  new.access_level:=case when new.role in ('owner','portal_manager','coadmin') then 'manage'
    when new.role='viewer' then 'read' else 'live' end;
  return new;
end $$;
create trigger poortkamer_sync_owner_access before insert or update of role on app_private.portal_owners
for each row execute function app_private.poortkamer_sync_access_level();
create trigger poortkamer_sync_invite_access before insert or update of role on app_private.portal_team_invites
for each row execute function app_private.poortkamer_sync_access_level();

create or replace function app_private.poortkamer_role(_portal uuid,_actor uuid default auth.uid()) returns text
language sql stable security definer set search_path='' as $$
  select case when app_private.has_capability(p.event_id,'event_admin',_actor)
      or app_private.has_capability(p.event_id,'portals_manage',_actor)
      or app_private.has_capability(p.event_id,'live_support',_actor) then 'admin'
    else (select role from app_private.portal_owners
      where portal_id=p.id and user_id=_actor and revoked_at is null and suspended_at is null) end
  from app_private.portals p
  where p.id=_portal and p.approval_status='approved' and _actor is not null
$$;

create or replace function app_private.poortkamer_community(_event uuid,_actor uuid default auth.uid()) returns boolean
language sql stable security definer set search_path='' as $$
  select _actor is not null and (
    app_private.has_capability(_event,'event_admin',_actor)
    or app_private.has_capability(_event,'portals_manage',_actor)
    or app_private.has_capability(_event,'live_support',_actor)
    or exists(select 1 from app_private.portal_owners o
      join app_private.portals p on p.id=o.portal_id
      where p.event_id=_event and p.approval_status='approved'
        and o.user_id=_actor and o.revoked_at is null and o.suspended_at is null))
$$;

create or replace function app_private.poortkamer_require(_portal uuid,_level text default 'read') returns text
language plpgsql stable security definer set search_path='' as $$
declare r text:=app_private.poortkamer_role(_portal); access text;
begin
  if r='admin' then return r; end if;
  select access_level into access from app_private.portal_owners
    where portal_id=_portal and user_id=auth.uid() and revoked_at is null and suspended_at is null;
  if r is null or (_level='live' and access not in ('live','manage'))
    or (_level='details' and access<>'manage')
    or (_level='team' and r<>'owner') then
    raise exception 'NOT_AUTHORIZED' using errcode='42501';
  end if;
  return r;
end $$;

create or replace function app_private.poortenboek_banner_options() returns jsonb
language sql immutable set search_path='' as $$
  select '{"shape":["shield","swallowtail","round","split"],"color":["amber","cyan","violet","emerald","crimson","moonlight"],"secondaryColor":["amber","cyan","violet","emerald","crimson","moonlight"],"border":["rope","metal","thorns","stars"],"symbol":["gate","moon","flame","ghost","key","star","bat","pumpkin"],"lantern":["classic","moon","tower","crystal"],"glow":["warm","cold","magic","mist"]}'::jsonb
$$;

create function app_private.poortenboek_valid_banner(_choices jsonb) returns boolean
language sql immutable set search_path='' as $$
  select jsonb_typeof(_choices)='object' and not exists(
    select 1 from jsonb_each(app_private.poortenboek_banner_options()) expected
    where not (_choices ? expected.key)
       or not ((_choices->>expected.key)=any(array(select jsonb_array_elements_text(expected.value))))
  ) and (select count(*) from jsonb_object_keys(_choices))=7
$$;

create function app_private.poortenboek_resolve_banner(_event uuid,_team uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; eligible integer; voters integer; category text; winner text;
begin
  perform pg_advisory_xact_lock(hashtextextended(_event::text||':'||_team::text||':banner',0));
  insert into app_private.poortenboek_team_customizations(event_id,team_id) values(_event,_team) on conflict do nothing;
  select banner into result from app_private.poortenboek_team_customizations where event_id=_event and team_id=_team for update;
  if result is not null then return result; end if;
  select count(*) into eligible from app_private.poortenboek_members(_event,_team);
  select count(*) into voters from app_private.poortenboek_banner_votes where event_id=_event and team_id=_team;
  if eligible=0 or voters<eligible then return null; end if;
  result:='{}'::jsonb;
  foreach category in array array['shape','color','secondaryColor','border','symbol','lantern','glow'] loop
    select choice into winner from (
      select choices->>category choice,count(*) votes,
        md5(_event::text||_team::text||category||(choices->>category)) tie
      from app_private.poortenboek_banner_votes where event_id=_event and team_id=_team
      group by choices->>category order by votes desc,tie limit 1
    ) ranked;
    result:=result||jsonb_build_object(category,winner);
  end loop;
  update app_private.poortenboek_team_customizations set banner=result,decided_at=now(),updated_at=now()
    where event_id=_event and team_id=_team;
  return result;
end $$;

create function app_private.poortenboek_record_completed_stop() returns trigger
language plpgsql security definer set search_path='' as $$
declare eventid uuid; portalid uuid; worldid uuid; active_presentation app_private.portal_presentations;
  participant record; teamid uuid; total_stops integer; completed_stops integer; chapter integer;
  presentation jsonb; is_finale boolean;
begin
  if new.state<>'completed' or old.state='completed' or new.outcome not in ('visited','mixed') then return new; end if;
  select g.event_id,coalesce(new.portal_id,plan.portal_id),p.world_id,coalesce(new.stop_kind='finale',false)
    into eventid,portalid,worldid,is_finale
  from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id
  left join app_private.route_plan_stops plan on plan.id=new.plan_stop_id
  join app_private.portals p on p.id=coalesce(new.portal_id,plan.portal_id)
  where r.id=new.run_id;
  perform pg_advisory_xact_lock(hashtextextended(portalid::text||':presentation',0));
  select * into active_presentation from app_private.portal_presentations
    where portal_id=portalid and status='active' order by version desc limit 1;
  if active_presentation.id is null then
    insert into app_private.portal_presentations(
      portal_id,version,status,world_id,public_name,short_description,story_fragment,
      symbol,color,image_path,accessibility,intensity,created_by,submitted_at,
      reviewed_by,reviewed_at,activated_at)
    select p.id,coalesce((select max(version)+1 from app_private.portal_presentations where portal_id=p.id),1),
      'active',p.world_id,coalesce(nullif(pub.published_title,''),p.name),
      coalesce(nullif(pub.teaser,''),'Een goedgekeurde poort uit de nacht van Duindorp.'),
      left(coalesce(nullif(w.story,''),'Achter deze poort werd de nacht even een andere wereld.'),1200),
      'gate','amber',case when pub.image_path ~ '^/images/[A-Za-z0-9_./-]+[.]webp$' then pub.image_path end,
      'Volg de aanwijzingen van de groepsleider.',p.intensity,o.user_id,now(),o.user_id,now(),now()
    from app_private.portals p join app_private.worlds w on w.id=p.world_id
    join lateral (select user_id from app_private.portal_owners where portal_id=p.id and role='owner' and revoked_at is null order by accepted_at limit 1) o on true
    left join app_private.portal_publications pub on pub.portal_id=p.id
    where p.id=portalid
    returning * into active_presentation;
  end if;
  if active_presentation.id is not null then
    presentation:=jsonb_build_object('version',active_presentation.version,'portalCode',(select system_code from app_private.portals where id=portalid),
      'world',(select name from app_private.worlds where id=active_presentation.world_id),'worldSlug',(select slug from app_private.worlds where id=active_presentation.world_id),'publicName',active_presentation.public_name,
      'shortDescription',active_presentation.short_description,'story',active_presentation.story_fragment,
      'symbol',active_presentation.symbol,'color',active_presentation.color,'imagePath',active_presentation.image_path,
      'accessibility',active_presentation.accessibility,'intensity',active_presentation.intensity);
  else
    select jsonb_build_object('version',pub.version,'portalCode',p.system_code,'world',w.name,'worldSlug',w.slug,'publicName',coalesce(nullif(pub.published_title,''),p.name),
      'shortDescription',coalesce(nullif(pub.teaser,''),'Een poort uit de nacht van Duindorp.'),'story',w.story,
      'symbol','gate','color','amber','imagePath',pub.image_path,'accessibility','Volg de aanwijzingen van de groepsleider.','intensity',p.intensity)
      into presentation from app_private.portals p join app_private.worlds w on w.id=p.world_id
      left join app_private.portal_publications pub on pub.portal_id=p.id where p.id=portalid;
  end if;
  for participant in
    select distinct rc.child_id from app_private.stop_participant_statuses status
    join app_private.run_participants rp on rp.id=status.run_participant_id
    join app_private.registration_children rc on rc.id=rp.registration_child_id
    where status.run_stop_id=new.id and status.status='visited' and rp.attendance='present' and rc.participation_status='active'
  loop
    teamid:=app_private.poortenboek_team(eventid,participant.child_id);
    if teamid is null then continue; end if;
    insert into app_private.poortenboek_team_progress(event_id,team_id,run_id,run_stop_id,portal_id,world_id,completed_at,finale)
      values(eventid,teamid,new.run_id,new.id,portalid,worldid,new.completed_at,is_finale) on conflict do nothing;
    insert into app_private.poortenboek_passport_seals(event_id,child_id,team_id,run_id,run_stop_id,portal_id,world_id,presentation_id,presentation_snapshot,earned_at,finale)
      values(eventid,participant.child_id,teamid,new.run_id,new.id,portalid,worldid,active_presentation.id,presentation,new.completed_at,is_finale)
      on conflict do nothing;
    insert into app_private.poortenboek_story_chapters(event_id,child_id,chapter,source_run_id,source_stop_id)
      values(eventid,participant.child_id,1,new.run_id,new.id),(eventid,participant.child_id,2,new.run_id,new.id) on conflict do nothing;
    select count(*) into total_stops from app_private.run_stops where run_id=new.run_id;
    select count(*) into completed_stops from app_private.poortenboek_team_progress where event_id=eventid and team_id=teamid and run_id=new.run_id;
    if completed_stops*3>=greatest(total_stops,1) then
      insert into app_private.poortenboek_story_chapters values(eventid,participant.child_id,3,new.run_id,new.id,now()) on conflict do nothing;
    end if;
    if completed_stops*3>=greatest(total_stops,1)*2 then
      insert into app_private.poortenboek_story_chapters values(eventid,participant.child_id,4,new.run_id,new.id,now()) on conflict do nothing;
    end if;
    if is_finale or completed_stops>=greatest(total_stops-1,1) then
      insert into app_private.poortenboek_story_chapters values(eventid,participant.child_id,5,new.run_id,new.id,now()) on conflict do nothing;
    end if;
    if is_finale then
      insert into app_private.poortenboek_story_chapters values(eventid,participant.child_id,6,new.run_id,new.id,now()) on conflict do nothing;
    end if;
  end loop;
  perform realtime.send(jsonb_build_object('runStopId',new.id),'snapshot_changed','admin-event:'||eventid,true);
  return new;
end $$;
create trigger poortenboek_record_completed_stop after update of state on app_private.run_stops
for each row when(old.state is distinct from new.state) execute function app_private.poortenboek_record_completed_stop();

create function app_private.poortenboek_record_finale_assignment() returns trigger
language plpgsql security definer set search_path='' as $$
declare eventid uuid; participant record;
begin
  if new.state<>'active' or new.stop_kind<>'finale' then return new; end if;
  select g.event_id into eventid from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id where r.id=new.run_id;
  for participant in select distinct rc.child_id from app_private.run_participants rp
    join app_private.registration_children rc on rc.id=rp.registration_child_id
    where rp.run_id=new.run_id and rp.attendance='present' and rc.participation_status='active'
  loop
    insert into app_private.poortenboek_story_chapters(event_id,child_id,chapter,source_run_id,source_stop_id)
      values(eventid,participant.child_id,5,new.run_id,new.id) on conflict do nothing;
  end loop;
  return new;
end $$;
create trigger poortenboek_record_finale_assignment after insert or update of state on app_private.run_stops
for each row execute function app_private.poortenboek_record_finale_assignment();

-- V2 uses one private favourites round: each selected name is one vote. Existing
-- round-two elections can still close safely, while new round-one elections no
-- longer expose or require an intermediate tally.
create or replace function app_private.poortenboek_scores(_election uuid)
returns table(option_id uuid,sparks bigint,final_votes bigint) language sql stable set search_path='' as $$
  select opt.id,
    coalesce((select count(*) from app_private.poortenboek_ballots b,
      unnest(b.choices) choice(id) where b.election_id=e.id and b.round='round_one' and choice.id=opt.id),0)::bigint,
    (select count(*) from app_private.poortenboek_ballots b where b.election_id=e.id and b.round in('round_two','direct') and b.choices[1]=opt.id)
  from app_private.poortenboek_elections e join app_private.poortenboek_name_options opt on opt.id=any(e.option_ids) where e.id=_election
$$;

create or replace function app_private.poortenboek_advance(_id uuid) returns app_private.poortenboek_elections
language plpgsql set search_path='' as $$
declare e app_private.poortenboek_elections; votes integer; winner uuid; tied integer; score bigint;
begin
  select * into e from app_private.poortenboek_elections where id=_id for update;
  if e.phase='round_one' then
    select count(*) into votes from app_private.poortenboek_ballots where election_id=e.id and round='round_one';
    if votes=cardinality(e.eligible_children) or now()>=e.round_one_deadline then
      if votes>0 then
        select option_id,sparks into winner,score from app_private.poortenboek_scores(e.id)
          order by sparks desc,md5(e.event_id::text||e.team_id::text||option_id::text) limit 1;
        select count(*) into tied from app_private.poortenboek_scores(e.id) where sparks=score;
        update app_private.poortenboek_elections set phase='finished',winner_id=winner,magic_tiebreak=tied>1 where id=e.id returning * into e;
        insert into app_private.audit_events(event_id,action,resource_type,resource_id,minimal_change)
          values(e.event_id,'poortenboek.team_name_decided','together_party',e.team_id,
            jsonb_build_object('electionId',e.id,'generation',e.generation,'ballots',votes,'magicTiebreak',tied>1));
      end if;
    end if;
  elsif e.phase in ('round_two','direct') then
    select count(*) into votes from app_private.poortenboek_ballots where election_id=e.id and round=e.phase;
    if votes=cardinality(e.eligible_children) or now()>=e.round_two_deadline then
      if votes>0 then
        select option_id,final_votes into winner,score from app_private.poortenboek_scores(e.id)
          where e.phase='direct' or option_id=any(e.finalists)
          order by final_votes desc,sparks desc,md5(e.event_id::text||e.team_id::text||option_id::text) limit 1;
        select count(*) into tied from app_private.poortenboek_scores(e.id) where (e.phase='direct' or option_id=any(e.finalists)) and final_votes=score;
        update app_private.poortenboek_elections set phase='finished',winner_id=winner,magic_tiebreak=tied>1 where id=e.id returning * into e;
        insert into app_private.audit_events(event_id,action,resource_type,resource_id,minimal_change)
          values(e.event_id,'poortenboek.team_name_decided','together_party',e.team_id,
            jsonb_build_object('electionId',e.id,'generation',e.generation,'ballots',votes,'magicTiebreak',tied>1));
      end if;
    end if;
  end if;
  return e;
end $$;

-- Extend the private child snapshot without weakening the existing V1 contract.
alter function app_private.poortenboek_snapshot(app_private.poortenboek_sessions) rename to poortenboek_snapshot_v1;
create function app_private.poortenboek_snapshot(_session app_private.poortenboek_sessions) returns jsonb
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
  select count(*) into visits from app_private.poortenboek_team_progress where event_id=c.event_id and team_id=team;
  select count(*) into assigned from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id
    join app_private.walking_groups g on g.id=r.group_id join app_private.group_registrations gr on gr.group_id=g.id and gr.superseded_at is null
    join app_private.registration_children rc on rc.registration_id=gr.registration_id and rc.child_id=c.child_id where g.event_id=c.event_id;
  select e.phase::text into phase from app_private.events e where e.id=c.event_id;
  if phase in ('completed','archived') then
    insert into app_private.poortenboek_story_chapters(event_id,child_id,chapter)
      values(c.event_id,c.child_id,5),(c.event_id,c.child_id,6) on conflict do nothing;
  end if;
  return base||jsonb_build_object(
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
      'chapters',coalesce((select jsonb_agg(jsonb_build_object('chapter',chapter,'unlockedAt',unlocked_at) order by chapter) from app_private.poortenboek_story_chapters where event_id=c.event_id and child_id=c.child_id),'[]'::jsonb),
      'seals',coalesce((select jsonb_agg(jsonb_build_object('portalId',s.portal_id,'worldId',s.world_id,'earnedAt',s.earned_at,'finale',s.finale,'presentation',s.presentation_snapshot) order by s.earned_at) from app_private.poortenboek_passport_seals s where s.event_id=c.event_id and s.child_id=c.child_id),'[]'::jsonb),
      'complete',exists(select 1 from app_private.poortenboek_story_chapters where event_id=c.event_id and child_id=c.child_id and chapter=6)),
    'v2',true);
end $$;

alter function api.poortenboek_child_action(text,text,jsonb,uuid) rename to poortenboek_child_action_v1;
create function api.poortenboek_child_action(_token_hash text,_action text,_payload jsonb default '{}',_request_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s app_private.poortenboek_sessions; c app_private.poortenboek_codes; team uuid; old_hash text; body_hash text;
  e app_private.poortenboek_elections; choices uuid[]; expected_round text;
begin
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

alter function api.poortenboek_parent(uuid,text,text,uuid,text,text,text) rename to poortenboek_parent_v1;
create function api.poortenboek_parent(_actor uuid,_event_slug text,_action text,_child_id uuid default null,_digest text default null,_ciphertext text default null,_reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; eventid uuid; teamid uuid; custom app_private.poortenboek_team_customizations;
begin
  result:=api.poortenboek_parent_v1(_actor,_event_slug,_action,_child_id,_digest,_ciphertext,_reason);
  if _action='reset' then
    select id into eventid from app_private.events where slug=_event_slug;
    teamid:=app_private.poortenboek_team(eventid,_child_id);
    insert into app_private.poortenboek_team_customizations(event_id,team_id) values(eventid,teamid) on conflict do nothing;
    select * into custom from app_private.poortenboek_team_customizations where event_id=eventid and team_id=teamid for update;
    if custom.reset_count>=1 then raise exception 'TEAM_RESET_USED'; end if;
    delete from app_private.poortenboek_banner_votes where event_id=eventid and team_id=teamid;
    update app_private.poortenboek_team_customizations set banner=null,decided_at=null,reset_count=reset_count+1,updated_at=now()
      where event_id=eventid and team_id=teamid;
    insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
      values(eventid,_actor,'poortenboek.team_identity_reset','together_party',teamid,jsonb_build_object('reason',trim(_reason),'resetCount',1));
  end if;
  return result;
end $$;

alter function api.poortenboek_admin(uuid,text,text,jsonb) rename to poortenboek_admin_v1;
create function api.poortenboek_admin(_actor uuid,_event_slug text,_action text,_payload jsonb default '{}')
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
  return result;
end $$;

-- Portal presentation, incident and simulation commands are isolated from route state.
create function api.portal_v2_command(_portal_id uuid,_operation text,_payload jsonb,_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.portals; result jsonb; item app_private.portal_presentations; sim app_private.portal_simulation_runs;
  receipt app_private.command_receipts; request_hash text; incident app_private.portal_incidents;
begin
  select * into p from app_private.portals where id=_portal_id for update;
  perform app_private.poortkamer_require(_portal_id,case when _operation like 'presentation_%' then 'details' else 'live' end);
  request_hash:=encode(extensions.digest(convert_to(jsonb_build_array(_portal_id,_operation,_payload)::text,'utf8'),'sha256'),'hex');
  select * into receipt from app_private.command_receipts where actor_id=auth.uid() and command_type='portal.v2' and idempotency_key=_key::text;
  if found then if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return receipt.safe_result; end if;
  perform app_private.poortkamer_budget('portal_v2',30);
  if _operation='incident_create' then
    if (_payload->>'category') not in ('crowding','lingering','technical','nuisance','unsafe','contact_requested','other')
      or (_payload->>'urgency') not in ('normal','high') or char_length(trim(_payload->>'description')) not between 10 and 1000 then raise exception 'INVALID_INCIDENT'; end if;
    insert into app_private.portal_incidents(event_id,portal_id,category,urgency,description,callback_requested,created_by)
      values(p.event_id,p.id,_payload->>'category',_payload->>'urgency',trim(_payload->>'description'),coalesce((_payload->>'callbackRequested')::boolean,false),auth.uid()) returning * into incident;
    insert into app_private.portal_incident_history(incident_id,status,actor_id) values(incident.id,'new',auth.uid());
    result:=jsonb_build_object('id',incident.id,'status',incident.status);
    insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
      values(p.event_id,auth.uid(),'portal.incident.reported','portal_incident',incident.id,jsonb_build_object('portalId',p.id,'category',incident.category,'urgency',incident.urgency));
    if incident.urgency='high' then
      insert into app_private.portal_push_outbox(user_id,portal_id,kind,dedupe_key)
        select distinct capability.user_id,p.id,'incident','incident:'||incident.id
        from app_private.event_capabilities capability where capability.event_id=p.event_id and capability.revoked_at is null
          and capability.capability in ('event_admin','portals_manage','live_support') on conflict do nothing;
      perform realtime.send(jsonb_build_object('incidentId',incident.id,'portalId',p.id),'snapshot_changed','admin-event:'||p.event_id,true);
    end if;
  elsif _operation='incident_status' then
    select * into incident from app_private.portal_incidents where id=(_payload->>'incidentId')::uuid and portal_id=p.id for update;
    if incident.id is null or (_payload->>'status') not in ('seen','in_progress','resolved','closed') then raise exception 'INVALID_INCIDENT'; end if;
    update app_private.portal_incidents set status=_payload->>'status',updated_at=now(),resolved_by=case when _payload->>'status' in ('resolved','closed') then auth.uid() end,resolved_at=case when _payload->>'status' in ('resolved','closed') then now() end where id=incident.id;
    insert into app_private.portal_incident_history(incident_id,status,actor_id,note) values(incident.id,_payload->>'status',auth.uid(),nullif(trim(_payload->>'note'),''));
    result:=jsonb_build_object('id',incident.id,'status',_payload->>'status');
  elsif _operation in ('presentation_save','presentation_submit') then
    if char_length(trim(_payload->>'publicName')) not between 2 and 120 or char_length(trim(_payload->>'shortDescription')) not between 10 and 500
      or char_length(trim(_payload->>'story')) not between 10 and 1200 or (_payload->>'symbol') not in ('gate','moon','flame','ghost','key','star','bat','pumpkin')
      or (_payload->>'color') not in ('amber','cyan','violet','emerald','crimson','moonlight')
      or coalesce((_payload->>'intensity')::integer,p.intensity) not between 1 and 4
      or char_length(coalesce(nullif(trim(_payload->>'accessibility'),''),'Geen extra informatie opgegeven')) not between 2 and 300 then raise exception 'INVALID_PRESENTATION'; end if;
    insert into app_private.portal_presentations(portal_id,version,status,world_id,public_name,short_description,story_fragment,symbol,color,image_path,accessibility,intensity,created_by,submitted_at)
      values(p.id,coalesce((select max(version)+1 from app_private.portal_presentations where portal_id=p.id),1),case when _operation='presentation_submit' then 'submitted' else 'draft' end,
        p.world_id,trim(_payload->>'publicName'),trim(_payload->>'shortDescription'),trim(_payload->>'story'),_payload->>'symbol',_payload->>'color',nullif(_payload->>'imagePath',''),
        coalesce(nullif(trim(_payload->>'accessibility'),''),'Geen extra informatie opgegeven'),coalesce((_payload->>'intensity')::smallint,p.intensity),auth.uid(),case when _operation='presentation_submit' then now() end)
      returning * into item;
    result:=jsonb_build_object('id',item.id,'version',item.version,'status',item.status);
  elsif _operation='presentation_activate' then
    select * into item from app_private.portal_presentations where id=(_payload->>'presentationId')::uuid and portal_id=p.id and status='approved' for update;
    if item.id is null then raise exception 'PRESENTATION_NOT_APPROVED'; end if;
    update app_private.portal_presentations set status='retired' where portal_id=p.id and status='active';
    update app_private.portal_presentations set status='active',activated_at=now() where id=item.id;
    result:=jsonb_build_object('id',item.id,'status','active');
  elsif _operation='simulation_start' then
    if exists(select 1 from app_private.portal_simulation_runs where portal_id=p.id and state='running') then raise exception 'SIMULATION_ACTIVE'; end if;
    insert into app_private.portal_simulation_runs(event_id,portal_id,created_by) values(p.event_id,p.id,auth.uid()) returning * into sim;
    insert into app_private.portal_simulation_events(simulation_run_id,phase,created_by) values(sim.id,sim.phase,auth.uid());
    result:=jsonb_build_object('id',sim.id,'phase',sim.phase,'simulation',true);
  elsif _operation='simulation_step' then
    select * into sim from app_private.portal_simulation_runs where id=(_payload->>'simulationRunId')::uuid and portal_id=p.id and state='running' for update;
    if sim.id is null or (_payload->>'phase') not in ('quiet','open','approaching','arrived','busy','paused','stopped','incident','chat','seal','finale','completed') then raise exception 'INVALID_SIMULATION'; end if;
    update app_private.portal_simulation_runs set phase=_payload->>'phase',state=case when _payload->>'phase'='completed' then 'completed' else state end,
      scenario=scenario||case _payload->>'phase'
        when 'arrived' then '{"visits":1,"children":8}'::jsonb
        when 'busy' then '{"visits":2,"children":14}'::jsonb
        when 'incident' then '{"incident":true}'::jsonb
        when 'chat' then '{"chatTested":true}'::jsonb
        when 'seal' then '{"sealTested":true}'::jsonb
        when 'finale' then '{"finaleTested":true,"visits":3,"children":20}'::jsonb
        else '{}'::jsonb end,updated_at=now() where id=sim.id;
    insert into app_private.portal_simulation_events(simulation_run_id,phase,created_by) values(sim.id,_payload->>'phase',auth.uid());
    result:=jsonb_build_object('id',sim.id,'phase',_payload->>'phase','simulation',true);
  elsif _operation='simulation_reset' then
    select * into sim from app_private.portal_simulation_runs where id=(_payload->>'simulationRunId')::uuid and portal_id=p.id for update;
    if sim.id is null then raise exception 'INVALID_SIMULATION'; end if;
    delete from app_private.portal_simulation_runs where id=sim.id;
    result:=jsonb_build_object('id',sim.id,'reset',true,'simulation',true);
  else raise exception 'INVALID_OPERATION'; end if;
  insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
    values(auth.uid(),'portal.v2',_key::text,request_hash,result,now()+interval '30 days');
  perform app_private.poortkamer_signal(p.id,'portal.v2.'||_operation,result,null);
  return result;
end $$;

alter function api.portal_room_update(uuid,text,jsonb,uuid) rename to portal_room_update_v1;
create function api.portal_room_update(_portal_id uuid,_operation text,_payload jsonb,_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  if _operation in ('incident_create','incident_status','presentation_save','presentation_submit','presentation_activate','simulation_start','simulation_step','simulation_reset') then
    return api.portal_v2_command(_portal_id,_operation,_payload,_key);
  end if;
  return api.portal_room_update_v1(_portal_id,_operation,_payload,_key);
end $$;

-- Map the richer UI roles onto the V1 invitation transaction, then persist the
-- explicit role and access level without changing invitation security.
alter function api.portal_team_command(uuid,text,jsonb,uuid) rename to portal_team_command_v1;
create function api.portal_team_command(_portal_id uuid,_operation text,_payload jsonb,_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare requested text:=_payload->>'role'; mapped jsonb:=_payload; result jsonb;
  access text:=coalesce(_payload->>'accessLevel',case requested when 'portal_manager' then 'manage' when 'viewer' then 'read' else 'live' end);
  p app_private.portals; member app_private.portal_owners; target uuid;
  receipt app_private.command_receipts; request_hash text;
begin
  if _operation in ('access','suspend','reactivate') then
    select * into p from app_private.portals where id=_portal_id for update;
    perform app_private.poortkamer_require(_portal_id,'team');
    request_hash:=encode(extensions.digest(convert_to(jsonb_build_array(_portal_id,_operation,_payload)::text,'UTF8'),'sha256'),'hex');
    select * into receipt from app_private.command_receipts
      where actor_id=auth.uid() and command_type='portal.team.v2' and idempotency_key=_key::text;
    if found then
      if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      return receipt.safe_result;
    end if;
    perform app_private.poortkamer_budget('team',10);
    target:=(_payload->>'userId')::uuid;
    select * into member from app_private.portal_owners
      where portal_id=_portal_id and user_id=target and revoked_at is null for update;
    if member.user_id is null then raise exception 'MEMBER_NOT_FOUND'; end if;
    if member.role='owner' then raise exception 'TRANSFER_OWNER_FIRST'; end if;
    if _operation='access' then
      if access not in ('read','live','manage') then raise exception 'INVALID_ACCESS_LEVEL'; end if;
      update app_private.portal_owners set access_level=access
        where portal_id=_portal_id and user_id=target and revoked_at is null;
    elsif _operation='suspend' then
      update app_private.portal_owners set suspended_at=now()
        where portal_id=_portal_id and user_id=target and revoked_at is null;
    else
      update app_private.portal_owners set suspended_at=null
        where portal_id=_portal_id and user_id=target and revoked_at is null;
    end if;
    result:=jsonb_build_object('userId',target,'operation',_operation,'accessLevel',access);
    perform app_private.poortkamer_email(p.event_id,target,'portal_team_role_changed','portal-access:'||_key,jsonb_build_object('portalCode',p.system_code));
    insert into app_private.portal_push_outbox(user_id,portal_id,kind,dedupe_key)
      values(target,p.id,'access','access:'||_key) on conflict do nothing;
    perform app_private.poortkamer_signal(p.id,'portal.team.'||_operation,result,
      case _operation when 'suspend' then 'Een teamlid is tijdelijk gedeactiveerd.'
        when 'reactivate' then 'Een teamlid heeft weer toegang.'
        else 'Het toegangsniveau van een teamlid is gewijzigd.' end);
    insert into app_private.command_receipts(actor_id,command_type,idempotency_key,request_hash,safe_result,expires_at)
      values(auth.uid(),'portal.team.v2',_key::text,request_hash,result,now()+interval '30 days');
    return result;
  end if;
  if _operation in ('invite','role') and requested in ('portal_manager','actor','reception','tech','viewer') then
    if access not in ('read','live','manage') then raise exception 'INVALID_ACCESS_LEVEL'; end if;
    mapped:=jsonb_set(mapped,'{role}',to_jsonb(case when requested='portal_manager' then 'coadmin' when requested='viewer' then 'viewer' else 'crew' end));
    result:=api.portal_team_command_v1(_portal_id,_operation,mapped,_key);
    if _operation='invite' then update app_private.portal_team_invites set role=requested,access_level=access where id=(result->>'id')::uuid;
    else update app_private.portal_owners set role=requested,access_level=access where portal_id=_portal_id and user_id=(_payload->>'userId')::uuid and revoked_at is null; end if;
    return result;
  end if;
  return api.portal_team_command_v1(_portal_id,_operation,_payload,_key);
end $$;

alter function api.portal_invitation_accept(text) rename to portal_invitation_accept_v1;
create function api.portal_invitation_accept(_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; access text;
begin
  select access_level into access from app_private.portal_team_invites
    where token_hash=extensions.digest(_token,'sha256');
  result:=api.portal_invitation_accept_v1(_token);
  update app_private.portal_owners set access_level=coalesce(access,access_level)
    where portal_id=(result->>'portalId')::uuid and user_id=auth.uid() and revoked_at is null;
  return result;
end $$;

create function app_private.poortkamer_v2_snapshot(_portal uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'presentation',coalesce((select jsonb_build_object('id',id,'version',version,'status',status,'publicName',public_name,
      'world',(select name from app_private.worlds where id=world_id),'shortDescription',short_description,'story',story_fragment,'symbol',symbol,'color',color,'imagePath',image_path,'accessibility',accessibility,'intensity',intensity,'reviewNote',review_note)
      from app_private.portal_presentations where portal_id=_portal order by (status='active') desc,version desc limit 1),'null'::jsonb),
    'presentationVersions',coalesce((select jsonb_agg(jsonb_build_object('id',id,'version',version,'status',status,'publicName',public_name,'reviewNote',review_note) order by version desc)
      from app_private.portal_presentations where portal_id=_portal),'[]'::jsonb),
    'incidents',coalesce((select jsonb_agg(jsonb_build_object('id',id,'category',category,'urgency',urgency,'status',status,'description',description,'callbackRequested',callback_requested,'resolutionMessage',resolution_message,'createdAt',created_at) order by (status not in ('resolved','closed')) desc,created_at desc)
      from (select * from app_private.portal_incidents where portal_id=_portal order by created_at desc limit 100) i),'[]'::jsonb),
    'simulation',coalesce((select jsonb_build_object('id',id,'phase',phase,'state',state,'scenario',scenario,'updatedAt',updated_at,'simulation',true)
      from app_private.portal_simulation_runs where portal_id=_portal order by created_at desc limit 1),'null'::jsonb),
    'liveLog',coalesce((select jsonb_agg(jsonb_build_object('groupCode',g.code,'visitedAt',s.completed_at,'children',(select count(*) from app_private.stop_participant_statuses ps where ps.run_stop_id=s.id and ps.status='visited')) order by s.completed_at desc)
      from (select rs.* from app_private.run_stops rs left join app_private.route_plan_stops plan on plan.id=rs.plan_stop_id where coalesce(rs.portal_id,plan.portal_id)=_portal and rs.state='completed' and rs.outcome in ('visited','mixed') order by rs.completed_at desc limit 100) s
      join app_private.group_runs r on r.id=s.run_id join app_private.walking_groups g on g.id=r.group_id),'[]'::jsonb),
    'teamHistory',coalesce((select jsonb_agg(jsonb_build_object('action',action,'at',created_at,'change',minimal_change) order by created_at desc)
      from (select action,created_at,minimal_change from app_private.audit_events
        where resource_type='portal' and resource_id=_portal and action like 'portal.team.%'
        order by created_at desc limit 50) history),'[]'::jsonb),
    'simulationLabel',true)
$$;

alter function api.portal_room_snapshot(text,uuid) rename to portal_room_snapshot_v1;
create function api.portal_room_snapshot(_event_slug text,_portal_id uuid default null) returns jsonb
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
    'role',o.role,'task',o.task_label,'lastSeenAt',o.last_seen_at,'accessLevel',o.access_level,'suspendedAt',o.suspended_at)
    order by (o.role='owner') desc,o.accepted_at)
    from app_private.portal_owners o left join app_private.profiles pr on pr.user_id=o.user_id
    where o.portal_id=pid and o.revoked_at is null),'[]'::jsonb));
  return base||jsonb_build_object('v2',app_private.poortkamer_v2_snapshot(pid));
end $$;

alter function api.admin_portal_room_snapshot(text) rename to admin_portal_room_snapshot_v1;
create function api.admin_portal_room_snapshot(_event_slug text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare base jsonb; eid uuid;
begin
  base:=api.admin_portal_room_snapshot_v1(_event_slug);
  select id into eid from app_private.events where slug=_event_slug;
  return base||jsonb_build_object(
    'incidents',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'portalId',i.portal_id,'portalCode',p.system_code,'portalName',p.name,'category',i.category,'urgency',i.urgency,'status',i.status,'description',i.description,'callbackRequested',i.callback_requested,'assignedTo',i.assigned_to,'createdAt',i.created_at) order by (i.urgency='high') desc,i.created_at desc) from app_private.portal_incidents i join app_private.portals p on p.id=i.portal_id where i.event_id=eid and i.status not in ('resolved','closed')),'[]'::jsonb),
    'presentations',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'portalId',v.portal_id,'portalCode',p.system_code,'version',v.version,'status',v.status,'publicName',v.public_name,'submittedAt',v.submitted_at) order by v.submitted_at) from app_private.portal_presentations v join app_private.portals p on p.id=v.portal_id where p.event_id=eid and v.status in ('submitted','changes_requested')),'[]'::jsonb));
end $$;

create function api.admin_portal_v2_command(_event_slug text,_operation text,_id uuid,_payload jsonb,_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid; presentation app_private.portal_presentations; incident app_private.portal_incidents; result jsonb;
begin
  select id into eid from app_private.events where slug=_event_slug;
  if auth.uid() is null or not (app_private.has_capability(eid,'event_admin') or app_private.has_capability(eid,'portals_manage') or app_private.has_capability(eid,'live_support')) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(_key::text,0));
  if _operation in ('presentation_approve','presentation_changes','presentation_reject') then
    select v.* into presentation from app_private.portal_presentations v join app_private.portals p on p.id=v.portal_id where v.id=_id and p.event_id=eid for update;
    if presentation.id is null or presentation.status not in ('submitted','changes_requested') then raise exception 'INVALID_PRESENTATION'; end if;
    if _operation in ('presentation_changes','presentation_reject') and char_length(trim(_payload->>'note')) not between 5 and 500 then raise exception 'REVIEW_NOTE_REQUIRED'; end if;
    update app_private.portal_presentations set status=case when _operation='presentation_approve' then 'approved' when _operation='presentation_reject' then 'rejected' else 'changes_requested' end,
      reviewed_by=auth.uid(),reviewed_at=now(),review_note=nullif(trim(_payload->>'note'),'') where id=presentation.id;
    result:=jsonb_build_object('id',presentation.id,'status',case when _operation='presentation_approve' then 'approved' when _operation='presentation_reject' then 'rejected' else 'changes_requested' end);
  elsif _operation='incident_status' then
    select * into incident from app_private.portal_incidents where id=_id and event_id=eid for update;
    if incident.id is null or (_payload->>'status') not in ('seen','in_progress','resolved','closed') then raise exception 'INVALID_INCIDENT'; end if;
    update app_private.portal_incidents set status=_payload->>'status',updated_at=now(),assigned_to=case when _payload->>'status' in ('seen','in_progress') then auth.uid() else assigned_to end,
      resolved_by=case when _payload->>'status' in ('resolved','closed') then auth.uid() end,resolved_at=case when _payload->>'status' in ('resolved','closed') then now() end,
      admin_note=coalesce(nullif(trim(_payload->>'adminNote'),''),admin_note),resolution_message=coalesce(nullif(trim(_payload->>'resolutionMessage'),''),resolution_message) where id=incident.id;
    insert into app_private.portal_incident_history(incident_id,status,actor_id,note) values(incident.id,_payload->>'status',auth.uid(),coalesce(nullif(trim(_payload->>'adminNote'),''),nullif(trim(_payload->>'resolutionMessage'),'')));
    result:=jsonb_build_object('id',incident.id,'status',_payload->>'status');
  else raise exception 'INVALID_OPERATION'; end if;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
    values(eid,auth.uid(),'portal.admin.'||_operation,case when _operation like 'incident%' then 'portal_incident' else 'portal_presentation' end,_id,result||jsonb_build_object('key',_key));
  perform realtime.send(jsonb_build_object('id',_id),'snapshot_changed','admin-event:'||eid,true);
  return result;
end $$;

-- The V2 Poortenplein sections are additive. The retired stock channel remains
-- stored for audit/history and is filtered from the V2 client snapshot.
create or replace function app_private.poortkamer_channels(_event uuid,_portal uuid default null) returns void
language plpgsql security definer set search_path='' as $$
begin
  update app_private.portal_room_channels set name='Mededelingen'
    where event_id=_event and kind='announcements' and name='De Omroeper'
      and not exists(select 1 from app_private.portal_room_channels x where x.event_id=_event and x.kind='announcements' and x.name='Mededelingen');
  update app_private.portal_room_channels set name='Hulp gevraagd'
    where event_id=_event and kind='community' and name='Hulp & materialen'
      and not exists(select 1 from app_private.portal_room_channels x where x.event_id=_event and x.kind='community' and x.name='Hulp gevraagd');
  update app_private.portal_room_channels set name='Decor en techniek'
    where event_id=_event and kind='community' and name='Decor & techniek'
      and not exists(select 1 from app_private.portal_room_channels x where x.event_id=_event and x.kind='community' and x.name='Decor en techniek');
  insert into app_private.portal_room_channels(event_id,kind,name) values
    (_event,'community','Voorbereiding'),(_event,'community','Hulp gevraagd'),
    (_event,'community','Decor en techniek'),(_event,'community','Tijdens de avond'),(_event,'announcements','Mededelingen') on conflict do nothing;
  if _portal is not null then insert into app_private.portal_room_channels(event_id,portal_id,kind,name) values(_event,_portal,'team','Achter de Poort') on conflict do nothing; end if;
end $$;
do $$ declare e uuid; begin for e in select id from app_private.events loop perform app_private.poortkamer_channels(e); end loop; end $$;

create or replace function api.worker_claim_portal_push(_allowed_emails text[] default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  with candidates as (
    select n.id from app_private.portal_push_outbox n
    where n.kind<>'news'
      and (_allowed_emails is null or exists(select 1 from auth.users u where u.id=n.user_id and lower(trim(u.email))=any(_allowed_emails)))
      and n.completed_at is null and n.available_at<=now() and (n.lease_until is null or n.lease_until<now())
    order by n.available_at limit 10 for update skip locked
  ), claimed as (
    update app_private.portal_push_outbox n set lease_until=now()+interval '2 minutes',attempts=attempts+1
      from candidates c where n.id=c.id returning n.*
  )
  select coalesce(jsonb_agg(jsonb_build_object('id',n.id,'kind',n.kind,'attempts',n.attempts,
    'targets',coalesce((select jsonb_agg(jsonb_build_object('subscriptionId',s.id,'endpoint',s.endpoint,'p256dh',s.p256dh,'auth',s.auth_secret))
      from app_private.push_subscriptions s join app_private.push_preferences pr on pr.user_id=s.user_id and pr.enabled
      left join app_private.portal_notification_preferences pref on pref.user_id=s.user_id
      where s.user_id=n.user_id and s.active and coalesce((to_jsonb(pref)->>n.kind)::boolean,true)
        and (n.kind='access'
          or (n.portal_id is not null and app_private.poortkamer_role(n.portal_id,n.user_id) is not null)
          or (n.kind='incident' and exists(select 1 from app_private.portals p join app_private.event_capabilities ec on ec.event_id=p.event_id and ec.user_id=n.user_id and ec.revoked_at is null and ec.capability in ('event_admin','portals_manage','live_support') where p.id=n.portal_id))
          or (n.kind='urgent' and exists(select 1 from app_private.portal_room_messages m join app_private.portal_room_channels c on c.id=m.channel_id where 'announcement:'||m.id=n.dedupe_key and app_private.poortkamer_community(c.event_id,n.user_id))))
        and not exists(select 1 from app_private.portal_push_deliveries d where d.notification_id=n.id and d.subscription_id=s.id)),'[]'::jsonb))),'[]'::jsonb)
    into result from claimed n;
  return result;
end $$;

alter table app_private.poortenboek_child_identity enable row level security;
alter table app_private.poortenboek_practice enable row level security;
alter table app_private.poortenboek_banner_votes enable row level security;
alter table app_private.poortenboek_team_customizations enable row level security;
alter table app_private.portal_presentations enable row level security;
alter table app_private.poortenboek_team_progress enable row level security;
alter table app_private.poortenboek_passport_seals enable row level security;
alter table app_private.poortenboek_story_chapters enable row level security;
alter table app_private.portal_incidents enable row level security;
alter table app_private.portal_incident_history enable row level security;
alter table app_private.portal_simulation_runs enable row level security;
alter table app_private.portal_simulation_events enable row level security;

revoke all on all tables in schema app_private from public,anon,authenticated;
revoke execute on function app_private.poortenboek_banner_options(),app_private.poortenboek_valid_banner(jsonb),app_private.poortenboek_resolve_banner(uuid,uuid),app_private.poortenboek_record_completed_stop(),app_private.poortenboek_record_finale_assignment(),app_private.poortenboek_snapshot(app_private.poortenboek_sessions),app_private.poortkamer_v2_snapshot(uuid),app_private.poortkamer_sync_access_level(),app_private.portal_presentation_immutable() from public,anon,authenticated;
revoke execute on function app_private.poortenboek_snapshot_v1(app_private.poortenboek_sessions),api.poortenboek_child_action_v1(text,text,jsonb,uuid),api.poortenboek_parent_v1(uuid,text,text,uuid,text,text,text),api.poortenboek_admin_v1(uuid,text,text,jsonb),api.portal_room_update_v1(uuid,text,jsonb,uuid),api.portal_team_command_v1(uuid,text,jsonb,uuid),api.portal_invitation_accept_v1(text),api.portal_room_snapshot_v1(text,uuid),api.admin_portal_room_snapshot_v1(text) from public,anon,authenticated;
revoke execute on function api.poortenboek_child_action(text,text,jsonb,uuid),api.poortenboek_parent(uuid,text,text,uuid,text,text,text),api.poortenboek_admin(uuid,text,text,jsonb),api.portal_room_update(uuid,text,jsonb,uuid),api.portal_team_command(uuid,text,jsonb,uuid),api.portal_invitation_accept(text),api.portal_room_snapshot(text,uuid),api.admin_portal_room_snapshot(text),api.admin_portal_v2_command(text,text,uuid,jsonb,uuid),api.portal_v2_command(uuid,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function api.portal_room_update(uuid,text,jsonb,uuid),api.portal_team_command(uuid,text,jsonb,uuid),api.portal_invitation_accept(text),api.portal_room_snapshot(text,uuid),api.admin_portal_room_snapshot(text),api.admin_portal_v2_command(text,text,uuid,jsonb,uuid) to authenticated;
grant execute on function api.poortenboek_child_action(text,text,jsonb,uuid),api.poortenboek_parent(uuid,text,text,uuid,text,text,text),api.poortenboek_admin(uuid,text,text,jsonb),api.portal_v2_command(uuid,text,jsonb,uuid) to service_role;

commit;
