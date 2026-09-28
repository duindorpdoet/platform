begin;

-- Versioned, private source of truth for the social Deelstudio. Browser clients
-- only receive the deliberately small projections exposed through api.*.
create table app_private.social_share_templates (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  template_key text not null check (template_key in (
    'participant','gate_owner','join_us','recruit_gate','recruit_helper',
    'team_reveal','world_reveal','countdown','participant_recap','gate_recap','general_event'
  )),
  name text not null check (char_length(trim(name)) between 3 and 100),
  status text not null check (status in ('live','archived')),
  allowed_roles text[] not null,
  available_formats text[] not null check (available_formats <@ array['story','feed','square','landscape','opengraph']::text[]),
  portrait_asset text not null check (portrait_asset ~ '^/images/social-share/[A-Za-z0-9_./-]+[.]webp$' and position('..' in portrait_asset)=0),
  landscape_asset text not null check (landscape_asset ~ '^/images/social-share/[A-Za-z0-9_./-]+[.]webp$' and position('..' in landscape_asset)=0),
  text_config jsonb not null default '{}'::jsonb check (jsonb_typeof(text_config)='object'),
  default_caption text not null check (char_length(default_caption) between 10 and 4000),
  cta_type text not null check (cta_type in ('event','registration','house_registration')),
  valid_from timestamptz,
  valid_until timestamptz,
  world_slug text,
  utm_campaign text check (utm_campaign is null or utm_campaign ~ '^[A-Za-z0-9_-]{1,80}$'),
  safe_areas jsonb not null default '{"portrait":{"x":0.08,"y":0.08,"width":0.84,"height":0.84},"landscape":{"x":0.07,"y":0.10,"width":0.86,"height":0.80}}'::jsonb,
  version integer not null check (version > 0),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  published_at timestamptz,
  unique(event_id,template_key,version),
  check(valid_from is null or valid_until is null or valid_from < valid_until)
);
create unique index social_share_templates_one_live
  on app_private.social_share_templates(event_id,template_key) where status='live';

create table app_private.social_share_generations (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references app_private.events(id) on delete cascade,
  template_id uuid not null references app_private.social_share_templates(id) on delete restrict,
  owner_user_id uuid references auth.users(id) on delete set null,
  anonymous_session_id uuid,
  context_kind text not null,
  context_id uuid,
  format text not null check (format in ('story','feed','square','landscape','opengraph')),
  style text not null check (style in ('event','world')),
  safe_payload jsonb not null check (jsonb_typeof(safe_payload)='object'),
  cache_key text not null check (cache_key ~ '^[a-f0-9]{64}$'),
  storage_path text not null check (storage_path ~ '^temporary/[a-f0-9-]+/[a-z]+[.]png$'),
  og_storage_path text not null check (og_storage_path ~ '^public/[a-f0-9]+/opengraph[.]png$'),
  status text not null default 'rendering' check (status in ('rendering','ready','failed')),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  asset_expires_at timestamptz not null,
  asset_deleted_at timestamptz,
  expires_at timestamptz not null,
  check(owner_user_id is not null or anonymous_session_id is not null)
);
create index social_share_generations_cache on app_private.social_share_generations(cache_key,status,expires_at desc);
create index social_share_generations_owner on app_private.social_share_generations(owner_user_id,created_at desc);

create table app_private.social_share_pages (
  id uuid primary key default gen_random_uuid(),
  public_share_id text not null unique check (public_share_id ~ '^[a-f0-9]{32}$'),
  generation_id uuid not null unique references app_private.social_share_generations(id) on delete cascade,
  safe_title text not null check (char_length(safe_title) between 3 and 180),
  safe_description text not null check (char_length(safe_description) between 10 and 500),
  cta_type text not null check (cta_type in ('event','registration','house_registration')),
  campaign_code text check (campaign_code is null or campaign_code ~ '^[A-Za-z0-9_-]{1,80}$'),
  noindex boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index social_share_pages_active on app_private.social_share_pages(public_share_id) where active;

create table app_private.social_share_events (
  id bigint generated always as identity primary key,
  event_id uuid not null references app_private.events(id) on delete cascade,
  share_page_id uuid references app_private.social_share_pages(id) on delete set null,
  template_id uuid references app_private.social_share_templates(id) on delete set null,
  actor_id uuid references auth.users(id) on delete set null,
  anonymous_session_id uuid,
  event_type text not null check (event_type in (
    'studio_opened','template_selected','preview_generated','image_downloaded',
    'caption_copied','link_copied','native_share_opened','platform_fallback_opened',
    'public_page_viewed','house_registration_started','house_registration_completed',
    'participant_registration_started','participant_registration_completed'
  )),
  platform text check (platform is null or platform in ('native','facebook','instagram','snapchat','whatsapp','x')),
  created_at timestamptz not null default now()
);
create index social_share_events_funnel on app_private.social_share_events(event_id,template_id,event_type,created_at desc);

alter table app_private.social_share_templates enable row level security;
alter table app_private.social_share_generations enable row level security;
alter table app_private.social_share_pages enable row level security;
alter table app_private.social_share_events enable row level security;
revoke all on table app_private.social_share_templates from public,anon,authenticated;
revoke all on table app_private.social_share_generations from public,anon,authenticated;
revoke all on table app_private.social_share_pages from public,anon,authenticated;
revoke all on table app_private.social_share_events from public,anon,authenticated;
revoke all on sequence app_private.social_share_events_id_seq from public,anon,authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('social-share-assets','social-share-assets',false,12582912,array['image/png','image/jpeg'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

with template(template_key,name,roles,portrait,landscape,caption,cta,config) as (values
  ('participant','Wij lopen mee',array['walker'], '/images/social-share/participant/participant-portrait.webp','/images/social-share/participant/participant-landscape.webp',
    E'Wij lopen mee met De Duindorpse Poorten van Halloween! 👻\n\nOp 31 oktober trekken we tijdens de Halloween-avondtocht langs de mysterieuze poorten van Duindorp.\n\nMeer informatie: {{public_event_url}}\n\n#DuindorpsePoorten #HalloweenDuindorp #Duindorp','event',
    '{"eyebrow":"SAMEN DOOR DE NACHT","title":"WIJ LOPEN MEE","subtitle":"DE DUINDORPSE POORTEN VAN HALLOWEEN","date":"31 OKTOBER 2026","publicDescription":"Wij lopen mee tijdens De Duindorpse Poorten van Halloween."}'::jsonb),
  ('gate_owner','Wij zijn een Poort',array['homeowner'], '/images/social-share/gate-owner/gate-owner-portrait.webp','/images/social-share/gate-owner/gate-owner-landscape.webp',
    E'Op 31 oktober verandert onze deur in één van de Duindorpse Poorten van Halloween. 🎃\n\nWij doen mee als officiële Poort en maken ons klaar voor een avond vol licht, mist en verrassingen.\n\nMeer informatie: {{public_event_url}}\n\n#DuindorpsePoorten #HalloweenDuindorp #Duindorp','event',
    '{"eyebrow":"ACHTER ONZE DEUR","title":"WIJ ZIJN EEN POORT","date":"31 OKTOBER 2026","publicDescription":"Een Duindorpse deur ontwaakt op 31 oktober."}'::jsonb),
  ('join_us','Loop jij met ons mee?',array['walker_lead'], '/images/social-share/join-us/join-us-portrait.webp','/images/social-share/join-us/join-us-landscape.webp',
    E'Loop jij op 31 oktober met ons mee?\n\nVraag ons persoonlijk om onze samenloopcode. Met die code kun je jouw inschrijving aan die van ons koppelen, zolang er ruimte is en de organisatie dit accepteert.\n\nInschrijven en informatie: {{public_event_url}}\n\n#DuindorpsePoorten #SamenDoorDeNacht #HalloweenDuindorp','registration',
    '{"eyebrow":"SAMEN DOOR DE NACHT","title":"LOOP JIJ MET ONS MEE?","subtitle":"VRAAG ONZE SAMENLOOPCODE!","date":"31 OKTOBER 2026","publicDescription":"Loop mee en vraag de deler persoonlijk om de samenloopcode."}'::jsonb),
  ('recruit_gate','Word ook een Poort',array['public'], '/images/social-share/recruit-gate/recruit-gate-portrait.webp','/images/social-share/recruit-gate/recruit-gate-landscape.webp',
    E'Laat jouw deur op 31 oktober ook ontwaken. 🕯️\n\nMeld jouw huis aan als Poort en maak samen met de buurt van Duindorp één grote Halloween-avondtocht.\n\nAanmelden: {{house_registration_url}}\n\n#DuindorpsePoorten #WordEenPoort #Duindorp','house_registration',
    '{"eyebrow":"WORD ONDERDEEL VAN HET VERHAAL","title":"LAAT JOUW DEUR OOK ONTWAKEN","subtitle":"MELD JOUW HUIS AAN ALS POORT","date":"31 OKTOBER 2026","publicDescription":"Meld jouw huis aan als Poort voor de Halloween-avondtocht."}'::jsonb),
  ('recruit_helper','Help mee bij onze Poort',array['homeowner'], '/images/social-share/recruit-helper/helper-portrait.webp','/images/social-share/recruit-helper/helper-landscape.webp',
    E'Onze Poort ontwaakt op 31 oktober en we zoeken nog een paar dappere helpers.\n\nWil jij helpen met decor, ontvangst of acteren? Laat het ons persoonlijk weten.\n\n#DuindorpsePoorten #HalloweenDuindorp','event',
    '{"eyebrow":"SAMEN MAKEN WE DE MAGIE","title":"HELP JIJ MEE BIJ ONZE POORT?","subtitle":"DECOR · ONTVANGST · ACTEREN","date":"31 OKTOBER 2026","publicDescription":"Help mee met decor, ontvangst of acteren bij een Poort."}'::jsonb),
  ('team_reveal','Ons team is klaar voor de nacht',array['walker'], '/images/social-share/team-reveal/team-reveal-portrait.webp','/images/social-share/team-reveal/team-reveal-landscape.webp',
    E'Ons team is klaar voor De Duindorpse Poorten van Halloween. 🌙\n\nOp 31 oktober trekken wij als {{safe_team_name}} door de Halloween-avond in Duindorp.\n\n{{public_event_url}}\n\n#DuindorpsePoorten #HalloweenDuindorp','event',
    '{"eyebrow":"ONS VAANDEL IS GEKOZEN","title":"ONS TEAM IS KLAAR VOOR DE NACHT","date":"31 OKTOBER 2026","publicDescription":"Een team is klaar voor de Halloweenavond in Duindorp."}'::jsonb),
  ('world_reveal','Onze wereld ontwaakt',array['homeowner'], '/images/social-share/world-reveal/world-reveal-portrait.webp','/images/social-share/world-reveal/world-reveal-landscape.webp',
    E'Onze wereld is ontwaakt…\n\nOp 31 oktober opent {{public_gate_name_optional}} de poort naar {{world_name}}.\n\nMeer informatie: {{public_event_url}}\n\n#DuindorpsePoorten #HalloweenDuindorp','event',
    '{"eyebrow":"ACHTER DE POORT","title":"ONZE WERELD ONTWAAKT","date":"31 OKTOBER 2026","publicDescription":"Een goedgekeurde wereld van De Duindorpse Poorten ontwaakt."}'::jsonb),
  ('countdown','Aftelkaart',array['public'], '/images/social-share/countdown/countdown-portrait.webp','/images/social-share/countdown/countdown-landscape.webp',
    E'Nog {{nights_remaining}} nachten tot de poorten van Duindorp openen. 🎃\n\nBen jij er klaar voor?\n\n{{public_event_url}}\n\n#DuindorpsePoorten #HalloweenDuindorp','event',
    '{"eyebrow":"HET AFTELLEN IS BEGONNEN","title":"NOG {{nights_remaining}} NACHTEN","subtitle":"TOT DE POORTEN OPENEN","date":"31 OKTOBER 2026","publicDescription":"Het aftellen naar De Duindorpse Poorten van Halloween is begonnen."}'::jsonb),
  ('participant_recap','Terugblik deelnemer',array['walker'], '/images/social-share/participant-recap/participant-recap-portrait.webp','/images/social-share/participant-recap/participant-recap-landscape.webp',
    E'Wat een avond! Wij liepen mee met De Duindorpse Poorten van Halloween en verzamelden onderweg onze eigen zegels.\n\nBedankt aan alle poorteigenaren, vrijwilligers en organisatie.\n\n#DuindorpsePoorten #HalloweenDuindorp','event',
    '{"eyebrow":"ONZE HERINNERING AAN DE NACHT","title":"WIJ LIEPEN MEE","date":"2026","publicDescription":"Een veilige terugblik op de Halloween-avondtocht."}'::jsonb),
  ('gate_recap','Terugblik poort',array['homeowner'], '/images/social-share/gate-recap/gate-recap-portrait.webp','/images/social-share/gate-recap/gate-recap-landscape.webp',
    E'Onze Poort was geopend tijdens De Duindorpse Poorten van Halloween.\n\nBedankt aan alle deelnemers, helpers, vrijwilligers en organisatie voor deze bijzondere avond.\n\n#DuindorpsePoorten #HalloweenDuindorp','event',
    '{"eyebrow":"DANK VOOR DEZE BIJZONDERE AVOND","title":"ONZE POORT WAS GEOPEND","date":"2026","publicDescription":"Een veilige terugblik van een Duindorpse Poort."}'::jsonb),
  ('general_event','Algemene eventkaart',array['public'], '/images/social-share/general/general-event-portrait.webp','/images/social-share/general/general-event-landscape.webp',
    E'De Duindorpse Poorten van Halloween komen eraan. 🌙\n\nOp 31 oktober verandert Duindorp in één grote Halloween-avondtocht.\n\nMeer informatie: {{public_event_url}}\n\n#DuindorpsePoorten #HalloweenDuindorp #Duindorp','event',
    '{"eyebrow":"HALLOWEEN AVONDLOOP","title":"DE DUINDORPSE POORTEN VAN HALLOWEEN","date":"31 OKTOBER 2026","publicDescription":"De Halloween-avondtocht door Duindorp op 31 oktober 2026."}'::jsonb)
)
insert into app_private.social_share_templates(
  event_id,template_key,name,status,allowed_roles,available_formats,portrait_asset,landscape_asset,
  text_config,default_caption,cta_type,valid_from,valid_until,utm_campaign,version,published_at
)
select event.id,template.template_key,template.name,'live',template.roles,
  array['story','feed','square','landscape','opengraph'],template.portrait,template.landscape,
  template.config || jsonb_build_object('publicEventPath','/','houseRegistrationPath','/huis-aanmelden'),
  template.caption,template.cta,
  case when template.template_key='countdown' then (event.local_date-interval '90 days')::timestamp at time zone event.timezone end,
  case when template.template_key='countdown' then (event.local_date+interval '1 day')::timestamp at time zone event.timezone end,
  'deelstudio-2026',1,now()
from app_private.events event cross join template
on conflict(event_id,template_key,version) do nothing;

-- This projection is the only place where role and ownership are translated to
-- shareable values. It never emits child names, addresses, contact details,
-- start data, routes, group/cluster identifiers or together codes.
create function app_private.social_share_cards(_event_id uuid,_actor uuid)
returns table(template_key text,context_kind text,context_id uuid,safe_payload jsonb)
language sql stable security definer set search_path='' as $$
with event_record as (
  select * from app_private.events where id=_event_id
), actor_registration as (
  select registration.*,coalesce(membership.party_id,registration.id) team_id
  from app_private.household_members member
  join app_private.registrations registration on registration.household_id=member.household_id
    and registration.event_id=_event_id and registration.status='submitted'
  left join app_private.together_memberships membership on membership.registration_id=registration.id and membership.left_at is null
  where _actor is not null and member.user_id=_actor and member.revoked_at is null
  order by registration.created_at,registration.id limit 1
), team_identity as (
  select actor_registration.id registration_id,actor_registration.household_id,actor_registration.team_id,
    option.label team_name,customization.banner,
    (select count(*) from app_private.poortenboek_team_progress progress
      where progress.event_id=_event_id and progress.team_id=actor_registration.team_id) visited_count
  from actor_registration
  left join lateral (
    select election.* from app_private.poortenboek_elections election
    where election.event_id=_event_id and election.team_id=actor_registration.team_id and election.phase='finished'
    order by election.generation desc limit 1
  ) election on true
  left join app_private.poortenboek_name_options option on option.id=election.winner_id
  left join app_private.poortenboek_team_customizations customization
    on customization.event_id=_event_id and customization.team_id=actor_registration.team_id and customization.decided_at is not null
), actor_portal as (
  select application.id application_id,application.review_status,portal.id portal_id,
    coalesce(presentation.public_name,publication.published_title,portal.name) portal_name,
    world.name world_name,presentation.color world_color,
    coalesce((select count(*) from app_private.scan_evidence evidence
      join app_private.run_stops stop on stop.id=evidence.run_stop_id
      join app_private.route_plan_stops plan_stop on plan_stop.id=stop.plan_stop_id
      where plan_stop.portal_id=portal.id),0) received_groups,
    coalesce((select count(*) from app_private.stop_participant_statuses participant
      join app_private.run_stops stop on stop.id=participant.run_stop_id
      join app_private.route_plan_stops plan_stop on plan_stop.id=stop.plan_stop_id
      where plan_stop.portal_id=portal.id and participant.status='visited'),0) estimated_visitors
  from app_private.portal_applications application
  left join app_private.portals portal on portal.application_id=application.id and portal.approval_status='approved'
  left join app_private.worlds world on world.id=portal.world_id
  left join app_private.portal_publications publication on publication.portal_id=portal.id and publication.published_at is not null
  left join app_private.portal_presentations presentation on presentation.portal_id=portal.id and presentation.status='active'
  where _actor is not null and application.event_id=_event_id
    and application.review_status in ('submitted','changes_requested','approved')
    and (application.applicant_user_id=_actor or exists(select 1 from app_private.portal_owners owner where owner.portal_id=portal.id and owner.user_id=_actor and owner.revoked_at is null and owner.suspended_at is null))
  order by (presentation.id is not null) desc,(portal.id is not null) desc,application.created_at desc limit 1
), cards as (
  select 1 priority,'general_event'::text key,'public'::text kind,null::uuid id,'{}'::jsonb payload
  union all select 2,'recruit_gate','public',null,'{}'::jsonb
  union all select 3,'countdown','public',null,jsonb_build_object('nightsRemaining',greatest(event_record.local_date-(now() at time zone event_record.timezone)::date,0)) from event_record
  union all select 10,'participant','registration',registration.id,'{}'::jsonb from actor_registration registration
  union all select 11,'join_us','together_party',party.id,'{}'::jsonb
    from actor_registration registration join app_private.together_parties party on party.id=registration.team_id
    where party.creator_household_id=registration.household_id
  union all select 12,'team_reveal','team',identity.team_id,jsonb_build_object('teamName',identity.team_name,'banner',identity.banner)
    from team_identity identity where identity.team_name is not null and identity.banner is not null
  union all select 13,'participant_recap','team',identity.team_id,jsonb_build_object('teamName',identity.team_name,'banner',identity.banner,'visitedCount',identity.visited_count)
    from team_identity identity,event_record where event_record.phase in ('completed','archived') and identity.team_name is not null and identity.banner is not null
  union all select 20,'gate_owner','portal_application',portal.application_id,
    jsonb_strip_nulls(jsonb_build_object('portalName',portal.portal_name,'worldName',portal.world_name,'worldColor',portal.world_color)) from actor_portal portal
  union all select 21,'recruit_helper','portal_application',portal.application_id,'{}'::jsonb from actor_portal portal
  union all select 22,'world_reveal','portal',portal.portal_id,
    jsonb_build_object('portalName',portal.portal_name,'worldName',portal.world_name,'worldColor',portal.world_color)
    from actor_portal portal where portal.portal_id is not null and portal.world_name is not null and portal.world_color is not null
  union all select 23,'gate_recap','portal',portal.portal_id,
    jsonb_build_object('portalName',portal.portal_name,'worldName',portal.world_name,'receivedGroups',portal.received_groups,'estimatedVisitors',portal.estimated_visitors)
    from actor_portal portal,event_record where portal.portal_id is not null and event_record.phase in ('completed','archived')
)
select cards.key,cards.kind,cards.id,cards.payload from cards order by cards.priority
$$;
revoke all on function app_private.social_share_cards(uuid,uuid) from public,anon,authenticated;

create function api.social_share_context(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); event_record app_private.events;
begin
  select * into event_record from app_private.events where slug=_event_slug;
  if event_record.id is null then return null; end if;
  return jsonb_build_object(
    'event',jsonb_build_object('title',event_record.title,'localDate',event_record.local_date,'timezone',event_record.timezone),
    'authenticated',actor is not null,
    'cards',coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',template.template_key,'name',template.name,'version',template.version,
        'formats',template.available_formats,'portraitAsset',template.portrait_asset,'landscapeAsset',template.landscape_asset,
        'textConfig',template.text_config,'defaultCaption',template.default_caption,'ctaType',template.cta_type,
        'dynamic',card.safe_payload,'worldStyleAvailable',(card.safe_payload ? 'worldColor')
      ) order by array_position(array['general_event','participant','gate_owner','join_us','recruit_gate','recruit_helper','team_reveal','world_reveal','countdown','participant_recap','gate_recap'],template.template_key))
      from app_private.social_share_cards(event_record.id,actor) card
      join app_private.social_share_templates template on template.event_id=event_record.id and template.template_key=card.template_key and template.status='live'
      where (template.valid_from is null or template.valid_from<=now()) and (template.valid_until is null or template.valid_until>now())
        and case card.context_kind
          when 'public' then 'public'=any(template.allowed_roles)
          when 'together_party' then 'walker_lead'=any(template.allowed_roles)
          when 'registration' then 'walker'=any(template.allowed_roles)
          when 'team' then 'walker'=any(template.allowed_roles)
          when 'portal_application' then 'homeowner'=any(template.allowed_roles)
          when 'portal' then 'homeowner'=any(template.allowed_roles)
          else false
        end
    ),'[]'::jsonb)
  );
end $$;

create function api.social_share_generation_reserve(
  _event_slug text,_actor uuid,_anonymous_session uuid,_template_key text,_format text,_style text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare event_record app_private.events; template app_private.social_share_templates; card record;
  generation app_private.social_share_generations; page app_private.social_share_pages; cache text; public_id text; payload jsonb;
begin
  select * into event_record from app_private.events where slug=_event_slug;
  if event_record.id is null or (_actor is null and _anonymous_session is null) then raise exception 'INVALID_INPUT'; end if;
  if _actor is not null and not exists(select 1 from auth.users where id=_actor) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  select * into card from app_private.social_share_cards(event_record.id,_actor) where template_key=_template_key limit 1;
  if card.template_key is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  select * into template from app_private.social_share_templates candidate
    where candidate.event_id=event_record.id and candidate.template_key=_template_key and candidate.status='live'
      and (candidate.valid_from is null or candidate.valid_from<=now()) and (candidate.valid_until is null or candidate.valid_until>now());
  if not (case card.context_kind
    when 'public' then 'public'=any(template.allowed_roles)
    when 'together_party' then 'walker_lead'=any(template.allowed_roles)
    when 'registration' then 'walker'=any(template.allowed_roles)
    when 'team' then 'walker'=any(template.allowed_roles)
    when 'portal_application' then 'homeowner'=any(template.allowed_roles)
    when 'portal' then 'homeowner'=any(template.allowed_roles)
    else false
  end) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if template.id is null or not (_format=any(template.available_formats)) or _style not in ('event','world')
    or (_style='world' and not(card.safe_payload ? 'worldColor')) then raise exception 'INVALID_INPUT'; end if;
  if (select count(*) from app_private.social_share_generations item where item.created_at>now()-interval '1 minute'
      and ((_actor is not null and item.owner_user_id=_actor) or (_actor is null and item.anonymous_session_id=_anonymous_session)))>=20
    then raise exception 'RATE_LIMITED'; end if;
  payload:=card.safe_payload||jsonb_build_object('eventTitle',event_record.title,'eventDate',event_record.local_date,'timezone',event_record.timezone);
  cache:=encode(extensions.digest(convert_to(template.id::text||':'||_format||':'||_style||':'||payload::text,'UTF8'),'sha256'),'hex');
  select item.* into generation from app_private.social_share_generations item
    where item.cache_key=cache and item.status='ready' and item.expires_at>now()
      and item.asset_expires_at>now() and item.asset_deleted_at is null
      and ((_actor is not null and item.owner_user_id=_actor) or (_actor is null and item.anonymous_session_id=_anonymous_session))
    order by item.completed_at desc limit 1;
  if generation.id is not null then
    select * into page from app_private.social_share_pages where generation_id=generation.id and active and expires_at>now();
    return jsonb_build_object('cached',true,'generationId',generation.id,'publicShareId',page.public_share_id,
      'storagePath',generation.storage_path,'ogStoragePath',generation.og_storage_path,'safePayload',generation.safe_payload,
      'template',jsonb_build_object('key',template.template_key,'name',template.name,'version',template.version,'portraitAsset',template.portrait_asset,'landscapeAsset',template.landscape_asset,'textConfig',template.text_config,'defaultCaption',template.default_caption,'ctaType',template.cta_type));
  end if;
  public_id:=encode(extensions.gen_random_bytes(16),'hex');
  insert into app_private.social_share_generations(event_id,template_id,owner_user_id,anonymous_session_id,context_kind,context_id,format,style,safe_payload,cache_key,storage_path,og_storage_path,asset_expires_at,expires_at)
  values(event_record.id,template.id,_actor,_anonymous_session,card.context_kind,card.context_id,_format,_style,payload,cache,
    'temporary/'||gen_random_uuid()::text||'/'||_format||'.png','public/'||public_id||'/opengraph.png',
    greatest(now()+interval '90 days',(event_record.local_date+interval '2 days')::timestamp at time zone event_record.timezone),
    greatest(now()+interval '1 year',(event_record.local_date+interval '1 year')::timestamp at time zone event_record.timezone)) returning * into generation;
  -- Object names use only random identifiers. Align the path with the generation id after insertion.
  update app_private.social_share_generations set storage_path='temporary/'||generation.id::text||'/'||_format||'.png' where id=generation.id returning * into generation;
  insert into app_private.social_share_pages(public_share_id,generation_id,safe_title,safe_description,cta_type,campaign_code,noindex,expires_at)
  values(public_id,generation.id,template.name||' · '||event_record.title,coalesce(template.text_config->>'publicDescription','Bekijk De Duindorpse Poorten van Halloween.'),template.cta_type,template.utm_campaign,
    template.template_key not in ('general_event','recruit_gate','countdown'),
    greatest(now()+interval '1 year',(event_record.local_date+interval '1 year')::timestamp at time zone event_record.timezone)) returning * into page;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
  values(event_record.id,_actor,'social_share.generation_reserved','social_share_generation',generation.id,
    jsonb_build_object('template',template.template_key,'version',template.version,'format',_format,'style',_style));
  return jsonb_build_object('cached',false,'generationId',generation.id,'publicShareId',page.public_share_id,
    'storagePath',generation.storage_path,'ogStoragePath',generation.og_storage_path,'safePayload',generation.safe_payload,
    'template',jsonb_build_object('key',template.template_key,'name',template.name,'version',template.version,'portraitAsset',template.portrait_asset,'landscapeAsset',template.landscape_asset,'textConfig',template.text_config,'defaultCaption',template.default_caption,'ctaType',template.cta_type));
end $$;

create function api.social_share_generation_complete(_generation_id uuid,_success boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  update app_private.social_share_generations set status=case when _success then 'ready' else 'failed' end,
    completed_at=case when _success then now() else null end where id=_generation_id and status='rendering';
  if not found then raise exception 'GENERATION_NOT_FOUND'; end if;
end $$;

create function api.social_share_asset(_generation_id uuid,_kind text)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('path',case when _kind='opengraph' then generation.og_storage_path else generation.storage_path end,
    'format',generation.format,'templateKey',template.template_key)
  from app_private.social_share_generations generation
  join app_private.social_share_templates template on template.id=generation.template_id
  join app_private.social_share_pages page on page.generation_id=generation.id
  where generation.id=_generation_id and generation.status='ready' and generation.expires_at>now()
    and (_kind='opengraph' or (generation.asset_expires_at>now() and generation.asset_deleted_at is null))
    and page.active and page.expires_at>now() and _kind in ('asset','opengraph')
$$;

create function api.social_share_public_asset(_public_share_id text,_kind text)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('generationId',generation.id,'path',case when _kind='opengraph' then generation.og_storage_path else generation.storage_path end,
    'format',generation.format,'templateKey',template.template_key)
  from app_private.social_share_pages page
  join app_private.social_share_generations generation on generation.id=page.generation_id
  join app_private.social_share_templates template on template.id=generation.template_id
  where page.public_share_id=_public_share_id and page.active and page.expires_at>now()
    and generation.status='ready' and _kind in ('asset','opengraph')
    and (_kind='opengraph' or (generation.asset_expires_at>now() and generation.asset_deleted_at is null))
$$;

create function api.social_share_public_page(_public_share_id text)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',page.public_share_id,'title',page.safe_title,'description',page.safe_description,
    'ctaType',page.cta_type,'campaign',page.campaign_code,'noindex',page.noindex,'templateKey',template.template_key,
    'templateName',template.name,'format',generation.format,'generationId',generation.id,'createdAt',page.created_at)
  from app_private.social_share_pages page
  join app_private.social_share_generations generation on generation.id=page.generation_id and generation.status='ready'
  join app_private.social_share_templates template on template.id=generation.template_id
  where page.public_share_id=_public_share_id and page.active and page.expires_at>now()
$$;

create function api.social_share_track(_event_slug text,_public_share_id text,_template_key text,_event_type text,_platform text,_session_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_event_id uuid; v_page_id uuid; v_template_id uuid;
begin
  if _event_type not in ('studio_opened','template_selected','preview_generated','image_downloaded','caption_copied','link_copied','native_share_opened','platform_fallback_opened','public_page_viewed','house_registration_started','house_registration_completed','participant_registration_started','participant_registration_completed')
    or (_platform is not null and _platform not in ('native','facebook','instagram','snapchat','whatsapp','x')) then raise exception 'INVALID_INPUT'; end if;
  select event.id into v_event_id from app_private.events event where event.slug=_event_slug;
  if v_event_id is null or _session_id is null then raise exception 'INVALID_INPUT'; end if;
  if _public_share_id is not null then
    select page.id,generation.template_id into v_page_id,v_template_id from app_private.social_share_pages page
      join app_private.social_share_generations generation on generation.id=page.generation_id
      where page.public_share_id=_public_share_id and page.active and page.expires_at>now();
  elsif _template_key is not null then
    select template.id into v_template_id from app_private.social_share_templates template
      where template.event_id=v_event_id and template.template_key=_template_key and template.status='live';
  end if;
  insert into app_private.social_share_events(event_id,share_page_id,template_id,actor_id,anonymous_session_id,event_type,platform)
  values(v_event_id,v_page_id,v_template_id,auth.uid(),_session_id,_event_type,_platform);
end $$;

create function api.admin_social_share_snapshot(_event_slug text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_event_id uuid;
begin
  select event.id into v_event_id from app_private.events event where event.slug=_event_slug;
  if v_event_id is null or not (app_private.has_capability(v_event_id,'event_admin') or app_private.has_capability(v_event_id,'communications_manage'))
    then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  return jsonb_build_object(
    'templates',coalesce((select jsonb_agg(jsonb_build_object('id',latest.id,'key',latest.template_key,'name',latest.name,'status',latest.status,
      'roles',latest.allowed_roles,'formats',latest.available_formats,'portraitAsset',latest.portrait_asset,'landscapeAsset',latest.landscape_asset,
      'textConfig',latest.text_config,'defaultCaption',latest.default_caption,'ctaType',latest.cta_type,'validFrom',latest.valid_from,'validUntil',latest.valid_until,
      'worldSlug',latest.world_slug,'utmCampaign',latest.utm_campaign,'safeAreas',latest.safe_areas,'version',latest.version,'publishedAt',latest.published_at)
      order by latest.template_key) from (select distinct on(template.template_key) template.* from app_private.social_share_templates template where template.event_id=v_event_id order by template.template_key,template.version desc) latest),'[]'::jsonb),
    'analytics',coalesce((select jsonb_agg(jsonb_build_object('templateKey',metric.template_key,'eventType',metric.event_type,'count',metric.total)
      order by metric.template_key,metric.event_type) from (select template.template_key,event.event_type,count(*) total
        from app_private.social_share_events event left join app_private.social_share_templates template on template.id=event.template_id
        where event.event_id=v_event_id group by template.template_key,event.event_type) metric),'[]'::jsonb)
  );
end $$;

create function api.admin_social_share_publish(
  _event_slug text,_template_key text,_active boolean,_roles text[],_formats text[],_portrait_asset text,_landscape_asset text,
  _text_config jsonb,_default_caption text,_valid_from timestamptz,_valid_until timestamptz,_world_slug text,_utm_campaign text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_event_id uuid; current_template app_private.social_share_templates; next_template app_private.social_share_templates;
begin
  select event.id into v_event_id from app_private.events event where event.slug=_event_slug for update;
  if v_event_id is null or not (app_private.has_capability(v_event_id,'event_admin') or app_private.has_capability(v_event_id,'communications_manage'))
    then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  select * into current_template from app_private.social_share_templates template where template.event_id=v_event_id and template.template_key=_template_key order by template.version desc limit 1 for update;
  if current_template.id is null or coalesce(array_length(_roles,1),0)=0 or not (_roles <@ array['public','walker','walker_lead','homeowner']::text[])
    or coalesce(array_length(_formats,1),0)=0 or not (_formats <@ array['story','feed','square','landscape','opengraph']::text[])
    or _portrait_asset !~ '^/images/social-share/[A-Za-z0-9_./-]+[.]webp$' or position('..' in _portrait_asset)>0
    or _landscape_asset !~ '^/images/social-share/[A-Za-z0-9_./-]+[.]webp$' or position('..' in _landscape_asset)>0
    or jsonb_typeof(_text_config)<>'object' or char_length(_default_caption) not between 10 and 4000
    or (_text_config-array['eyebrow','title','subtitle','date','publicDescription','publicEventPath','houseRegistrationPath'])<>'{}'::jsonb
    or exists(select 1 from jsonb_each(_text_config) value where jsonb_typeof(value.value)<>'string' or char_length(value.value#>>'{}')>500)
    or (_text_config->>'publicEventPath') !~ '^/[A-Za-z0-9/_-]*$' or (_text_config->>'houseRegistrationPath') !~ '^/[A-Za-z0-9/_-]*$'
    or (_default_caption||_text_config::text) ~* '<|>|laatste poort|eindpoort|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}|\m[1-9][0-9]{3}[ ]?[A-Z]{2}\M|\m(00|0[1-9]|1[0-9]|2[0-3]):[0-5][0-9]\M'
    or regexp_replace(_default_caption,'\{\{(public_event_url|house_registration_url|safe_team_name|public_gate_name_optional|world_name|nights_remaining)\}\}','','g') ~ '\{\{'
    or exists(select 1 from app_private.registrations registration where position(registration.together_code in _default_caption)>0)
    or (_world_slug is not null and _world_slug<>'' and _world_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$')
    or (_valid_from is not null and _valid_until is not null and _valid_from>=_valid_until)
    then raise exception 'INVALID_INPUT'; end if;
  update app_private.social_share_templates template set status='archived' where template.event_id=v_event_id and template.template_key=_template_key and template.status='live';
  insert into app_private.social_share_templates(event_id,template_key,name,status,allowed_roles,available_formats,portrait_asset,landscape_asset,text_config,
    default_caption,cta_type,valid_from,valid_until,world_slug,utm_campaign,safe_areas,version,created_by,published_at)
  values(v_event_id,current_template.template_key,current_template.name,case when _active then 'live' else 'archived' end,_roles,_formats,_portrait_asset,_landscape_asset,_text_config,
    _default_caption,current_template.cta_type,_valid_from,_valid_until,nullif(_world_slug,''),nullif(_utm_campaign,''),current_template.safe_areas,current_template.version+1,auth.uid(),case when _active then now() end)
  returning * into next_template;
  insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
  values(v_event_id,auth.uid(),'social_share.template_published','social_share_template',next_template.id,
    jsonb_build_object('template',_template_key,'version',next_template.version,'active',_active));
  return jsonb_build_object('id',next_template.id,'version',next_template.version,'status',next_template.status);
end $$;

-- The existing authenticated cron worker removes expired Storage objects first
-- and only then finalizes their database state. This keeps retries idempotent.
create function api.worker_social_share_cleanup_candidates(_limit integer default 50)
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'generationId',candidate.id,'kind',candidate.kind,'paths',candidate.paths
  ) order by candidate.created_at),'[]'::jsonb)
  from (
    select generation.id,generation.created_at,
      case when generation.expires_at<=now() then 'all' else 'asset' end kind,
      case when generation.expires_at<=now()
        then array[generation.storage_path,generation.og_storage_path]
        else array[generation.storage_path]
      end paths
    from app_private.social_share_generations generation
    where generation.expires_at<=now()
      or (generation.asset_expires_at<=now() and generation.asset_deleted_at is null)
    order by generation.created_at
    limit least(greatest(_limit,1),100)
  ) candidate
$$;

create function api.worker_social_share_cleanup_finalize(_generation_id uuid,_kind text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if _kind='asset' then
    update app_private.social_share_generations set asset_deleted_at=coalesce(asset_deleted_at,now()) where id=_generation_id;
  elsif _kind='all' then
    delete from app_private.social_share_generations where id=_generation_id and expires_at<=now();
  else raise exception 'INVALID_INPUT';
  end if;
end $$;

revoke all on function api.social_share_context(text) from public;
revoke all on function api.social_share_generation_reserve(text,uuid,uuid,text,text,text) from public,anon,authenticated;
revoke all on function api.social_share_generation_complete(uuid,boolean) from public,anon,authenticated;
revoke all on function api.social_share_asset(uuid,text) from public,anon,authenticated;
revoke all on function api.social_share_public_asset(text,text) from public,anon,authenticated;
revoke all on function api.social_share_public_page(text) from public;
revoke all on function api.social_share_track(text,text,text,text,text,uuid) from public;
revoke all on function api.admin_social_share_snapshot(text) from public,anon;
revoke all on function api.admin_social_share_publish(text,text,boolean,text[],text[],text,text,jsonb,text,timestamptz,timestamptz,text,text) from public,anon;
revoke all on function api.worker_social_share_cleanup_candidates(integer) from public,anon,authenticated;
revoke all on function api.worker_social_share_cleanup_finalize(uuid,text) from public,anon,authenticated;
grant execute on function api.social_share_context(text) to anon,authenticated;
grant execute on function api.social_share_generation_reserve(text,uuid,uuid,text,text,text) to service_role;
grant execute on function api.social_share_generation_complete(uuid,boolean) to service_role;
grant execute on function api.social_share_asset(uuid,text) to service_role;
grant execute on function api.social_share_public_asset(text,text) to service_role;
grant execute on function api.social_share_public_page(text) to anon,authenticated;
grant execute on function api.social_share_track(text,text,text,text,text,uuid) to anon,authenticated;
grant execute on function api.admin_social_share_snapshot(text) to authenticated;
grant execute on function api.admin_social_share_publish(text,text,boolean,text[],text[],text,text,jsonb,text,timestamptz,timestamptz,text,text) to authenticated;
grant execute on function api.worker_social_share_cleanup_candidates(integer) to service_role;
grant execute on function api.worker_social_share_cleanup_finalize(uuid,text) to service_role;

commit;
