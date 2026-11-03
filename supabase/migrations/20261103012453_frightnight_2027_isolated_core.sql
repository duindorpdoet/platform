-- FrightNight is deliberately isolated from legacy payment_requests, portals,
-- walking_groups and email_outbox. Existing auth and event capabilities are reused.
-- Every mutation resolves its event server-side; no client-supplied event_id.
create table app_private.fn_events (
 event_id uuid primary key references app_private.events(id),
 environment text not null check(environment='staging'), is_test boolean not null default true check(is_test),
 qr_required boolean not null default true, paused boolean not null default false, closed boolean not null default false,
 test_clock timestamptz, version integer not null default 1, seed_version integer not null default 0,
 run_id uuid not null default gen_random_uuid(), price_cents integer not null default 350 check(price_cents>=0),
 max_party integer not null default 20 check(max_party between 1 and 50),
 start_token_hash bytea, qr_secret bytea not null default extensions.gen_random_bytes(32), retention_until timestamptz not null default now()+interval '365 days',
 created_at timestamptz not null default now(), unique(event_id,run_id)
);
create table app_private.fn_registrations (
 id uuid primary key default gen_random_uuid(), event_id uuid not null references app_private.fn_events(event_id),
 owner_id uuid references auth.users(id), household_id uuid references app_private.households(id),
 terms_version text, consented_at timestamptz, consent_actor uuid references auth.users(id),
 contact_name text check(length(contact_name) between 1 and 120), contact_phone text check(length(contact_phone)<=25 and contact_phone~'^[0-9+(). /-]*$'),
 label text not null check(length(label) between 1 and 100), route_type text not null check(route_type in('lantern','roots')),
 adults integer not null check(adults between 1 and 20), children integer not null check(children between 0 and 20),
 max_intensity integer not null check(max_intensity between 1 and 5), avoid_smoke boolean not null default false,
 avoid_strobes boolean not null default false, step_free boolean not null default false, start_slot timestamptz,
 status text not null default 'draft' check(status in('draft','active','cancelled','archived')),
 payment_status text not null default 'unpaid' check(payment_status in('unpaid','open','paid','failed','cancelled','expired','refunded')),
 amount_cents integer not null check(amount_cents>=0), version integer not null default 1,
 synthetic boolean not null default false, run_id uuid not null, created_at timestamptz not null default now(),
 unique(event_id,id), unique(event_id,owner_id), check(owner_id is not null or synthetic), check(synthetic or (terms_version is not null and terms_version='2027-test-v1' and consented_at is not null and consent_actor is not null)), check(adults+children<=20), check(route_type<>'lantern' or max_intensity<=2)
);
create table app_private.fn_parties (
 id uuid primary key default gen_random_uuid(), event_id uuid not null references app_private.fn_events(event_id),
 state text not null default 'ready' check(state in('ready','walking','waiting','paused','finished','merged','archived')),
 reason text, version integer not null default 1, membership_version integer not null default 1,
 started_at timestamptz, finished_at timestamptz, run_id uuid not null, unique(event_id,id)
);
create table app_private.fn_members (
 event_id uuid not null, party_id uuid not null, registration_id uuid not null, joined_at timestamptz not null default now(),
 primary key(event_id,registration_id), foreign key(event_id,party_id) references app_private.fn_parties(event_id,id),
 foreign key(event_id,registration_id) references app_private.fn_registrations(event_id,id)
);
create index fn_members_party on app_private.fn_members(event_id,party_id);
create table app_private.fn_zones (
 id uuid primary key default gen_random_uuid(), event_id uuid not null references app_private.fn_events(event_id),
 owner_id uuid references auth.users(id), name text not null check(length(name) between 1 and 120),
 address text not null check(length(address) between 1 and 220), type text not null check(type in('candy','fright','finale')),
 intensity integer not null check(intensity between 0 and 5), capacity integer not null check(capacity between 1 and 1000),
 status text not null default 'closed' check(status in('open','busy','paused','closed')),
 pause_until timestamptz, pause_reason text check(length(pause_reason)<=500), review_status text not null default 'submitted' check(review_status in('submitted','approved','rejected')),
 smoke boolean not null default false, strobes boolean not null default false, step_free boolean not null default false,
 description text not null default '' check(length(description)<=2000), photo_path text, opens_at timestamptz not null, closes_at timestamptz not null,
 latitude double precision, longitude double precision, location_confirmed_at timestamptz, contact_confirmed_at timestamptz, visit_minutes integer not null default 5 check(visit_minutes between 1 and 30),
 token_hash bytea not null, token_version integer not null default 1, version integer not null default 1,
 synthetic boolean not null default false, run_id uuid not null, unique(event_id,id),
 check(opens_at<closes_at), check((type='candy' and intensity=0) or (type<>'candy' and intensity>=1))
);
create unique index fn_one_finale on app_private.fn_zones(event_id) where type='finale' and review_status='approved';
-- Verified walk edges only. Missing edges are not presented as a walking route.
create table app_private.fn_walk_edges (
 event_id uuid not null, from_zone_id uuid not null, to_zone_id uuid not null, minutes integer not null check(minutes between 1 and 120),
 geometry jsonb, source text not null default 'organisation-verified' check(source in('organisation-verified','synthetic-fixture')), verified boolean not null default false, primary key(event_id,from_zone_id,to_zone_id),
 foreign key(event_id,from_zone_id) references app_private.fn_zones(event_id,id),
 foreign key(event_id,to_zone_id) references app_private.fn_zones(event_id,id)
);
create table app_private.fn_destinations (
 id uuid primary key default gen_random_uuid(), event_id uuid not null, party_id uuid not null, zone_id uuid not null,
 sequence integer not null, state text not null default 'current' check(state in('current','visited','skipped','released')),
 persons integer not null check(persons>0), membership_version integer not null, arrival_at timestamptz not null,
 lease_until timestamptz not null, walk_minutes integer not null, reason text not null,
 created_at timestamptz not null default now(), unique(event_id,id), unique(party_id,sequence),
 foreign key(event_id,party_id) references app_private.fn_parties(event_id,id), foreign key(event_id,zone_id) references app_private.fn_zones(event_id,id),
 check(lease_until>arrival_at)
);
create unique index fn_one_current_destination on app_private.fn_destinations(party_id) where state='current';
create index fn_capacity_current on app_private.fn_destinations(event_id,zone_id) include(persons,lease_until,state) where state in('current','visited');
create table app_private.fn_visits (
 event_id uuid not null, registration_id uuid not null, destination_id uuid not null, zone_id uuid not null,
 method text not null check(method in('qr','released')), completed_at timestamptz not null,
 primary key(event_id,registration_id,zone_id), unique(registration_id,destination_id),
 foreign key(event_id,registration_id) references app_private.fn_registrations(event_id,id),
 foreign key(event_id,destination_id) references app_private.fn_destinations(event_id,id),
 foreign key(event_id,zone_id) references app_private.fn_zones(event_id,id)
);
create table app_private.fn_awards (
 event_id uuid not null, registration_id uuid not null, award_key text not null, created_at timestamptz not null default now(),
 primary key(event_id,registration_id,award_key), foreign key(event_id,registration_id) references app_private.fn_registrations(event_id,id)
);
create table app_private.fn_invites (
 id uuid primary key default gen_random_uuid(), event_id uuid not null, party_id uuid not null, token_hash bytea not null unique,
 expires_at timestamptz not null, consumed_by uuid references auth.users(id), revoked_at timestamptz,
 foreign key(event_id,party_id) references app_private.fn_parties(event_id,id)
);
create table app_private.fn_registration_invites (
 id uuid primary key default gen_random_uuid(), event_id uuid not null, registration_id uuid not null, invited_by uuid not null references auth.users(id),
 token_hash bytea not null unique, expires_at timestamptz not null, consumed_by uuid references auth.users(id), revoked_at timestamptz,
 foreign key(event_id,registration_id) references app_private.fn_registrations(event_id,id)
);
create table app_private.fn_activities (
 id uuid primary key default gen_random_uuid(), event_id uuid not null references app_private.fn_events(event_id),
 name text not null, starts_at timestamptz not null, ends_at timestamptz not null, capacity integer not null check(capacity>0),
 run_id uuid not null, unique(event_id,id), check(starts_at<ends_at)
);
create table app_private.fn_activity_staff (
 event_id uuid not null, activity_id uuid not null, user_id uuid not null references auth.users(id),
 primary key(event_id,activity_id,user_id), foreign key(event_id,activity_id) references app_private.fn_activities(event_id,id)
);
create table app_private.fn_bookings (
 id uuid primary key default gen_random_uuid(), event_id uuid not null, activity_id uuid not null, registration_id uuid not null,
 seats integer not null check(seats>0), status text not null default 'booked' check(status in('booked','cancelled','checked_in')),
 unique(event_id,registration_id,activity_id), foreign key(event_id,activity_id) references app_private.fn_activities(event_id,id),
 foreign key(event_id,registration_id) references app_private.fn_registrations(event_id,id)
);
create table app_private.fn_start_slots (
 event_id uuid not null references app_private.fn_events(event_id), starts_at timestamptz not null,
 route_type text not null check(route_type in('lantern','roots')), capacity integer not null default 100 check(capacity between 1 and 1000),
 primary key(event_id,starts_at)
);
create table app_private.fn_orders (
 id uuid primary key default gen_random_uuid(), event_id uuid not null, registration_id uuid not null,
 provider text not null default 'mollie' check(provider in('mollie','contract')), testmode boolean not null default true check(testmode),
 amount_cents integer not null check(amount_cents>=0), currency text not null default 'EUR' check(currency='EUR'),
 status text not null default 'open' check(status in('open','paid','failed','cancelled','expired','refunded')),
 provider_ref text unique, checkout_url text, hold_until timestamptz not null default now()+interval '15 minutes', idempotency_key uuid not null, created_at timestamptz not null default now(),
 unique(event_id,id), unique(event_id,idempotency_key),
 foreign key(event_id,registration_id) references app_private.fn_registrations(event_id,id)
);
create unique index fn_one_open_order on app_private.fn_orders(registration_id) where status='open';
create index fn_orders_registration_quote on app_private.fn_orders(event_id,registration_id,status);
create table app_private.fn_payment_events (
 event_id uuid not null, order_id uuid not null, provider_event text not null, status text not null,
 created_at timestamptz not null default now(), primary key(event_id,provider_event),
 foreign key(event_id,order_id) references app_private.fn_orders(event_id,id)
);
create table app_private.fn_ledger (
 id bigint generated always as identity primary key, event_id uuid not null, order_id uuid not null,
 kind text not null check(kind in('receipt','refund')), amount_cents integer not null, created_at timestamptz not null default now(),
 unique(order_id,kind), foreign key(event_id,order_id) references app_private.fn_orders(event_id,id)
);
create table app_private.fn_notifications (
 id uuid primary key default gen_random_uuid(), event_id uuid not null, registration_id uuid not null,
 title text not null, message text not null, dedupe_key text not null, read_at timestamptz, created_at timestamptz not null default now(),
 unique(event_id,registration_id,dedupe_key), foreign key(event_id,registration_id) references app_private.fn_registrations(event_id,id)
);
-- Sink records deliberately have no delivery worker or external recipient column.
-- A future allowlisted dispatcher must independently recheck environment and event.
create table app_private.fn_mail_sink (
 id uuid primary key default gen_random_uuid(), event_id uuid not null, registration_id uuid not null,
 environment text not null default 'staging' check(environment='staging'), delivery_mode text not null default 'sink' check(delivery_mode='sink'),
 dedupe_key text not null, template text not null, payload jsonb not null, attempts integer not null default 0,
 created_at timestamptz not null default now(), unique(event_id,registration_id,dedupe_key),
 foreign key(event_id,registration_id) references app_private.fn_registrations(event_id,id)
);
create table app_private.fn_push_subscriptions (
 event_id uuid not null references app_private.fn_events(event_id), actor_id uuid not null references auth.users(id), endpoint_hash bytea not null,
 endpoint text not null check(endpoint~'^https://[^/]+/.+' and length(endpoint)<=4096), p256dh text not null check(p256dh~'^[A-Za-z0-9_-]{87}=?$'), auth_key text not null check(auth_key~'^[A-Za-z0-9_-]{22}={0,2}$'),
 consent_at timestamptz not null default now(), revoked_at timestamptz, primary key(event_id,actor_id,endpoint_hash)
);
create table app_private.fn_announcements (
 id uuid primary key default gen_random_uuid(), event_id uuid not null references app_private.fn_events(event_id), text text not null check(length(text) between 1 and 2000),
 audience text not null default 'all' check(audience in('all','lantern','roots','registration','zone')), target_id uuid, version integer not null default 1,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check((audience in('registration','zone'))=(target_id is not null)), unique(event_id,id)
);
create table app_private.fn_incidents (
 id uuid primary key default gen_random_uuid(), event_id uuid not null references app_private.fn_events(event_id),
 actor_id uuid not null references auth.users(id), category text not null, text text not null check(length(text) between 1 and 2000),
 status text not null default 'open' check(status in('open','resolved')), response_text text, created_at timestamptz not null default now()
);
create table app_private.fn_thanks (
 event_id uuid not null, registration_id uuid not null, zone_id uuid not null, message text not null check(length(message) between 1 and 500), created_at timestamptz not null default now(),
 primary key(event_id,registration_id,zone_id), foreign key(event_id,registration_id) references app_private.fn_registrations(event_id,id), foreign key(event_id,zone_id) references app_private.fn_zones(event_id,id)
);
create table app_private.fn_evaluations (
 event_id uuid not null, registration_id uuid not null, rating integer not null check(rating between 1 and 5), message text not null check(length(message)<=2000), created_at timestamptz not null default now(),
 primary key(event_id,registration_id), foreign key(event_id,registration_id) references app_private.fn_registrations(event_id,id)
);
create table app_private.fn_content (
 event_id uuid not null references app_private.fn_events(event_id), content_key text not null check(content_key~'^[a-z0-9-]{1,80}$'), body jsonb not null, published boolean not null default false, version integer not null default 1,
 primary key(event_id,content_key)
);
create table app_private.fn_quests (
 event_id uuid not null references app_private.fn_events(event_id), id text not null, title text not null, question text not null,
 type text not null check(type in('riddle','game')), answer_hash bytea not null, primary key(event_id,id)
);
create table app_private.fn_receipts (
 event_id uuid not null references app_private.fn_events(event_id), actor_id uuid not null references auth.users(id),
 command_key uuid not null, request_hash bytea not null, result jsonb not null, created_at timestamptz not null default now(),
 primary key(event_id,actor_id,command_key)
);
create table app_private.fn_audit (
 id bigint generated always as identity primary key, event_id uuid not null references app_private.fn_events(event_id),
 actor_id uuid references auth.users(id), action text not null, details jsonb not null default '{}', created_at timestamptz not null default now()
);
create index fn_announcements_event_time on app_private.fn_announcements(event_id,created_at desc,id desc);
create index fn_incidents_event_status on app_private.fn_incidents(event_id,status,created_at desc,id);
create index fn_audit_event_time on app_private.fn_audit(event_id,created_at desc,id desc);
-- A single short event lock serializes commands and capacity accounting. This is a
-- deliberate correctness-first limit; no network/provider work occurs under it.
create function app_private.fn_now(p_event uuid) returns timestamptz language sql stable set search_path='' as $$ select coalesce(test_clock,now()) from app_private.fn_events where event_id=p_event $$;
create function app_private.fn_can(p_event uuid,p_cap text,p_actor uuid) returns boolean language sql stable security definer set search_path='' as $$ select app_private.has_capability(p_event,'event_admin',p_actor) or app_private.has_capability(p_event,p_cap,p_actor) $$;
create function app_private.fn_registration(p_event uuid,p_actor uuid) returns uuid language sql stable security definer set search_path='' as $$ select r.id from app_private.fn_registrations r where r.event_id=p_event and r.status<>'archived' and (r.owner_id=p_actor or (r.household_id is not null and app_private.is_household_member(r.household_id,p_actor))) order by (r.owner_id=p_actor) desc limit 1 $$;
create function app_private.fn_zone_status(p_zone uuid) returns text language sql stable set search_path='' as $$
 select case when z.status='paused' and z.pause_until is not null and z.pause_until<=app_private.fn_now(z.event_id) and z.review_status='approved' and app_private.fn_now(z.event_id)>=z.opens_at and app_private.fn_now(z.event_id)<z.closes_at then 'open' else z.status end from app_private.fn_zones z where id=p_zone
$$;
create function app_private.fn_zone_json(p_zone uuid,p_private boolean default false) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',id,'name',name,'type',type,'intensity',intensity,'capacity',capacity,'status',app_private.fn_zone_status(id),'pauseUntil',pause_until,'pauseReason',pause_reason,'reviewStatus',review_status,'smoke',smoke,'strobes',strobes,'stepFree',step_free,'description',description,'photoPath',photo_path,'version',version,'opensAt',opens_at,'closesAt',closes_at)
 ||case when p_private then jsonb_build_object('address',address,'latitude',latitude,'longitude',longitude,'locationConfirmedAt',location_confirmed_at,'contactConfirmedAt',contact_confirmed_at,'expectedVisitors',(select coalesce(sum(d.persons),0) from app_private.fn_destinations d where d.zone_id=z.id and (d.state='current' or (d.state='visited' and d.lease_until>app_private.fn_now(d.event_id))))) else '{}' end from app_private.fn_zones z where id=p_zone
$$;
create function app_private.fn_registration_json(p_id uuid) returns jsonb language sql stable set search_path='' as $$ select jsonb_build_object('id',id,'label',label,'termsVersion',terms_version,'consentedAt',consented_at,'routeType',route_type,'adults',adults,'children',children,'persons',adults+children,'maxIntensity',max_intensity,'avoidSmoke',avoid_smoke,'avoidStrobes',avoid_strobes,'stepFree',step_free,'startSlot',start_slot,'status',status,'paymentStatus',payment_status,'paymentQuoteLocked',exists(select 1 from app_private.fn_orders o where o.registration_id=p_id and o.event_id=app_private.fn_registrations.event_id),'amountCents',amount_cents,'version',version) from app_private.fn_registrations where id=p_id $$;
create function app_private.fn_party_preferences(p_party uuid) returns jsonb language sql stable set search_path='' as $$ select jsonb_build_object('persons',sum(r.adults+r.children),'maxIntensity',min(r.max_intensity),'avoidSmoke',bool_or(r.avoid_smoke),'avoidStrobes',bool_or(r.avoid_strobes),'stepFree',bool_or(r.step_free),'routeType',min(r.route_type),'members',jsonb_agg(jsonb_build_object('registrationId',r.id,'label',r.label,'persons',r.adults+r.children) order by r.id)) from app_private.fn_members m join app_private.fn_registrations r on r.event_id=m.event_id and r.id=m.registration_id where m.party_id=p_party $$;
create function app_private.fn_choose(p_event uuid,p_party uuid,p_return boolean default false) returns uuid language plpgsql security definer set search_path='' as $$
declare pref jsonb; t timestamptz; deadline timestamptz; finale uuid; previous uuid; chosen uuid; walk integer; seq integer; did uuid; occupied integer; considered integer:=0; capacity_rejected integer:=0; z record;
begin
 pref:=app_private.fn_party_preferences(p_party); t:=app_private.fn_now(p_event);
 -- Joins, departures and refunds share the caller's event lock. No path may
 -- reserve for a party containing an inactive, unpaid or foreign member.
 if not exists(select 1 from app_private.fn_members where party_id=p_party and event_id=p_event) or exists(select 1 from app_private.fn_members m left join app_private.fn_registrations r on r.id=m.registration_id and r.event_id=p_event where m.party_id=p_party and (m.event_id<>p_event or r.id is null or r.status<>'active' or r.payment_status<>'paid')) then
  update app_private.fn_destinations set state='released' where party_id=p_party and event_id=p_event and state='current';
  update app_private.fn_parties set state='paused',reason='Een inschrijving is niet actief en betaald. Stem eerst af met het hulppunt.' where id=p_party and event_id=p_event; return null;
 end if;
 if exists(select 1 from app_private.fn_events where event_id=p_event and paused) and not p_return then
  update app_private.fn_parties set state='paused',reason='De organisatie heeft de tocht gepauzeerd. Volg de aanwijzingen van de begeleiding.' where id=p_party; return null;
 end if;
 if exists(select 1 from app_private.fn_events where event_id=p_event and closed) then p_return:=true; end if;
 select (e.local_date+case when pref->>'routeType'='lantern' then time '18:30' else time '21:00' end) at time zone e.timezone into deadline from app_private.events e where e.id=p_event;
 select id into finale from app_private.fn_zones where event_id=p_event and type='finale' and review_status='approved';
 select zone_id into previous from app_private.fn_destinations where party_id=p_party order by sequence desc limit 1; previous:=coalesce(previous,finale);
 select coalesce(max(sequence),0)+1 into seq from app_private.fn_destinations where party_id=p_party;
 if t>=deadline then p_return:=true; end if;
 -- Only verified walking links can make a normal zone eligible. The finale always
 -- remains available as the safe return instruction, including after the window.
 for z in select a.*,coalesce(w.minutes,case when a.id=previous then 1 else 15 end) as walk,
  coalesce(back.minutes,15) as return_walk from app_private.fn_zones a
  left join app_private.fn_walk_edges w on w.event_id=p_event and w.from_zone_id=previous and w.to_zone_id=a.id and w.verified
  left join app_private.fn_walk_edges back on back.event_id=p_event and back.from_zone_id=a.id and back.to_zone_id=finale and back.verified
  where a.event_id=p_event and a.review_status='approved' and app_private.fn_zone_status(a.id) in('open','busy')
   and ((a.id=finale) or (not p_return and w.verified and back.verified and a.opens_at<=t+make_interval(mins=>w.minutes)
    and a.closes_at>=t+make_interval(mins=>w.minutes+a.visit_minutes)
    and t+make_interval(mins=>w.minutes+a.visit_minutes+back.minutes)<=deadline
    and (a.type='candy' or a.intensity<=(pref->>'maxIntensity')::integer)
    and (not(pref->>'avoidSmoke')::boolean or not a.smoke)
    and (not(pref->>'avoidStrobes')::boolean or not a.strobes)
    and (not(pref->>'stepFree')::boolean or a.step_free)))
   and not exists(select 1 from app_private.fn_members m join app_private.fn_visits v on v.registration_id=m.registration_id and v.zone_id=a.id where m.party_id=p_party)
   and not exists(select 1 from app_private.fn_destinations d where d.party_id=p_party and d.zone_id=a.id and d.state='skipped')
  order by (a.id=finale),coalesce(w.minutes,15)+(case when a.status='busy' then 5 else 0 end)+coalesce((select sum(cd.persons)*4.0/a.capacity from app_private.fn_destinations cd where cd.zone_id=a.id and (cd.state='current' or (cd.state='visited' and cd.lease_until>t))),0),(a.type<>'candy'),a.id
 loop
  considered:=considered+1;
  select coalesce(sum(d.persons),0) into occupied from app_private.fn_destinations d where d.zone_id=z.id and (d.state='current' or (d.state='visited' and d.lease_until>t));
  if occupied+(pref->>'persons')::integer<=z.capacity then chosen:=z.id; walk:=z.walk; exit; else capacity_rejected:=capacity_rejected+1; end if;
 end loop;
 if chosen is null then update app_private.fn_parties set state='waiting',reason='Er is nu geen passende plek vrij. Blijf op een veilige plek of ga naar het hulppunt op het Duinpad.' where id=p_party; insert into app_private.fn_audit(event_id,actor_id,action,details) values(p_event,auth.uid(),'route.decision',jsonb_build_object('partyId',p_party,'engineVersion','deterministic-v1','reason','no-eligible-capacity','candidatesConsidered',considered,'capacityRejected',capacity_rejected,'preferences',pref-'members','businessTime',t)); return null; end if;
 insert into app_private.fn_destinations(event_id,party_id,zone_id,sequence,persons,membership_version,arrival_at,lease_until,walk_minutes,reason)
 select p_event,p_party,chosen,seq,(pref->>'persons')::integer,membership_version,t+make_interval(mins=>walk),greatest(t+make_interval(mins=>walk+20),least(deadline,t+interval '40 minutes')),walk,
 case when chosen=finale then 'Keer terug naar Oogstdorp op het Duinpad voor de passende finale.' else 'Deze zone past bij jullie voorkeuren en heeft ruimte voor het hele gezelschap.' end from app_private.fn_parties where id=p_party returning id into did;
 update app_private.fn_parties set state='walking',reason=null where id=p_party; insert into app_private.fn_audit(event_id,actor_id,action,details) values(p_event,auth.uid(),'route.decision',jsonb_build_object('partyId',p_party,'destinationId',did,'zoneId',chosen,'engineVersion','deterministic-v1','eventVersion',(select version from app_private.fn_events where event_id=p_event),'routeVersion',(select version from app_private.fn_parties where id=p_party),'reason',case when chosen=finale then 'finale-return' else 'suitable-walk-capacity' end,'candidatesConsidered',considered,'capacityRejected',capacity_rejected,'preferences',pref-'members','businessTime',t)); return did;
end $$;
create function app_private.fn_slot_available(p_event uuid,p_slot timestamptz,p_registration uuid) returns integer language sql stable security definer set search_path='' as $$
 select s.capacity-coalesce((select sum(r.adults+r.children) from app_private.fn_registrations r where r.event_id=p_event and r.start_slot=p_slot and r.id is distinct from p_registration and
 ((r.status='active' and r.payment_status='paid') or exists(select 1 from app_private.fn_orders o where o.registration_id=r.id and o.status='open' and o.hold_until>now()))),0)::integer
 from app_private.fn_start_slots s where s.event_id=p_event and s.starts_at=p_slot
$$;
create function api.frightnight_snapshot(p_slug text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); eid uuid; rid uuid; pid uuid; reg jsonb; journey jsonb; current_destination jsonb; result jsonb; totals jsonb:='{}'; is_admin boolean; is_zone_admin boolean;
begin
 if actor is null then raise exception 'LOGIN_REQUIRED' using errcode='42501'; end if;
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test;
 if eid is null then raise exception 'EDITION_NOT_AVAILABLE' using errcode='22023'; end if;
 rid:=app_private.fn_registration(eid,actor); reg:=app_private.fn_registration_json(rid);
 if exists(select 1 from app_private.fn_registrations where id=rid and owner_id=actor) then reg:=reg||(select jsonb_build_object('contactName',contact_name,'contactPhone',contact_phone) from app_private.fn_registrations where id=rid and owner_id=actor); end if;
 is_admin:=app_private.fn_can(eid,'groups_manage',actor) or app_private.fn_can(eid,'registration_manage',actor);
 is_zone_admin:=app_private.fn_can(eid,'portals_manage',actor);
 select party_id into pid from app_private.fn_members where event_id=eid and registration_id=rid;
 select jsonb_build_object('id',d.id,'zoneId',d.zone_id,'sequence',d.sequence,'zone',app_private.fn_zone_json(d.zone_id,true),'leaseUntil',d.lease_until,'arrivalAt',d.arrival_at,'walkMinutes',d.walk_minutes,'reason',d.reason) into current_destination from app_private.fn_destinations d where d.party_id=pid and d.state='current';
 select jsonb_build_object('id',p.id,'version',p.version,'membershipVersion',p.membership_version,'state',p.state,'reason',p.reason,'current',current_destination,'party',app_private.fn_party_preferences(p.id)) into journey from app_private.fn_parties p where p.id=pid;
 select jsonb_build_object('event',jsonb_build_object('id',e.id,'slug',e.slug,'title',e.title,'date',e.local_date,'timezone',e.timezone,'version',f.version,'qrRequired',f.qr_required,'paused',f.paused,'closed',f.closed,'test',f.is_test,'environment',f.environment,'serverTime',app_private.fn_now(e.id),'priceCents',f.price_cents,'seedVersion',f.seed_version,'runId',f.run_id,'retentionUntil',f.retention_until),
 'startSlots',coalesce((select jsonb_agg(jsonb_build_object('startsAt',ss.starts_at,'routeType',ss.route_type,'capacity',ss.capacity,'available',app_private.fn_slot_available(eid,ss.starts_at,rid)) order by ss.starts_at) from app_private.fn_start_slots ss where ss.event_id=eid),'[]'),
 'actor',jsonb_build_object('id',actor,'capabilities',coalesce((select jsonb_agg(c.capability order by c.capability) from app_private.event_capabilities c where c.event_id=eid and c.user_id=actor and c.revoked_at is null),'[]')||case when exists(select 1 from app_private.fn_activity_staff where event_id=eid and user_id=actor) then '["activities_manage"]'::jsonb else '[]'::jsonb end),
 'pushEnabled',exists(select 1 from app_private.fn_push_subscriptions where event_id=eid and actor_id=actor and revoked_at is null),'registrationAccess',coalesce((select jsonb_agg(jsonb_build_object('userId',hm.user_id,'role',hm.relation_role,'label',coalesce(pr.display_name,'Gedeelde volwassene'))) from app_private.household_members hm left join app_private.profiles pr on pr.user_id=hm.user_id where hm.household_id=(select household_id from app_private.fn_registrations where id=rid and owner_id=actor) and hm.revoked_at is null),'[]'),'registration',reg,'journey',journey,'current',current_destination,
 'progress',jsonb_build_object('visits',coalesce((select jsonb_agg(jsonb_build_object('zoneId',v.zone_id,'name',z.name,'completedAt',v.completed_at) order by v.completed_at) from app_private.fn_visits v join app_private.fn_zones z on z.id=v.zone_id where v.registration_id=rid),'[]'),
 'awards',coalesce((select jsonb_agg(jsonb_build_object('key',a.award_key,'createdAt',a.created_at) order by a.created_at) from app_private.fn_awards a where a.registration_id=rid),'[]'),
 'sparks',(select count(*) from app_private.fn_awards a where a.registration_id=rid)),
 'activities',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'name',a.name,'startsAt',a.starts_at,'endsAt',a.ends_at,'capacity',a.capacity,'available',a.capacity-coalesce((select sum(b.seats) from app_private.fn_bookings b where b.activity_id=a.id and b.status in('booked','checked_in')),0)) order by a.starts_at) from app_private.fn_activities a where a.event_id=eid and a.run_id=f.run_id),'[]'),
 'bookings',coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'activityId',b.activity_id,'seats',b.seats,'status',b.status)) from app_private.fn_bookings b where b.registration_id=rid),'[]'),
 'notifications',coalesce((select jsonb_agg(jsonb_build_object('id',n.id,'title',n.title,'message',n.message,'readAt',n.read_at,'createdAt',n.created_at) order by n.created_at desc) from (select * from app_private.fn_notifications nn where nn.registration_id=rid order by nn.created_at desc limit 100)n),'[]'),
 'announcements',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'text',a.text,'audience',a.audience,'targetId',a.target_id,'version',a.version,'createdAt',a.created_at,'updatedAt',a.updated_at) order by a.created_at desc,a.id) from (select * from app_private.fn_announcements aa where aa.event_id=eid and (app_private.fn_can(eid,'content_manage',actor) or (rid is not null and (aa.audience='all' or aa.audience=reg->>'routeType' or (aa.audience='registration' and aa.target_id=rid) or (aa.audience='zone' and aa.target_id=(current_destination->>'zoneId')::uuid)))) order by aa.created_at desc,aa.id limit 30)a),'[]'),
 'quests',coalesce((select jsonb_agg(jsonb_build_object('id',q.id,'title',q.title,'question',q.question,'type',q.type,'completed',exists(select 1 from app_private.fn_awards a where a.registration_id=rid and a.award_key='quest:'||q.id)) order by q.id) from app_private.fn_quests q where q.event_id=eid),'[]'),
 'ownIncidents',coalesce((select jsonb_agg(jsonb_build_object('id',ii.id,'category',ii.category,'text',ii.text,'status',ii.status,'response',ii.response_text,'createdAt',ii.created_at)) from (select * from app_private.fn_incidents where event_id=eid and actor_id=actor order by created_at desc limit 50)ii),'[]'),
 'ownThanks',coalesce((select jsonb_agg(jsonb_build_object('zoneId',zz.id,'count',(select count(*) from app_private.fn_thanks tt where tt.zone_id=zz.id),'messages',coalesce((select jsonb_agg(mt.message) from (select message from app_private.fn_thanks tt where tt.zone_id=zz.id order by created_at desc limit 20)mt),'[]'))) from app_private.fn_zones zz where zz.event_id=eid and zz.owner_id=actor),'[]'),
 'ownZones',coalesce((select jsonb_agg(app_private.fn_zone_json(z.id,true) order by z.name) from app_private.fn_zones z where z.event_id=eid and z.owner_id=actor),'[]')) into result
 from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.id=eid;
 if is_admin or is_zone_admin then result:=result||jsonb_build_object('zones',coalesce((select jsonb_agg(app_private.fn_zone_json(z.id,true) order by z.name) from (select zz.* from app_private.fn_zones zz join app_private.fn_events ff on ff.event_id=zz.event_id where zz.event_id=eid and zz.run_id=ff.run_id order by zz.name limit 100)z),'[]')); end if;
 if is_admin or app_private.fn_can(eid,'payments_manage',actor) then result:=result||jsonb_build_object('registrations',coalesce((select jsonb_agg(app_private.fn_registration_json(r.id) order by r.created_at desc) from (select * from app_private.fn_registrations rr where rr.event_id=eid and rr.status<>'archived' order by rr.created_at desc limit 100)r),'[]')); end if;
 if is_admin or app_private.fn_can(eid,'live_support',actor) then result:=result||jsonb_build_object('incidents',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'category',i.category,'text',i.text,'status',i.status) order by i.created_at desc) from (select * from app_private.fn_incidents ii where ii.event_id=eid order by ii.created_at desc limit 100)i),'[]')); end if;
 if app_private.has_capability(eid,'event_admin',actor) then result:=result||jsonb_build_object('audit',coalesce((select jsonb_agg(t.obj) from (select jsonb_build_object('id',a.id,'action',a.action,'createdAt',a.created_at) obj from app_private.fn_audit a where a.event_id=eid order by a.id desc limit 100)t),'[]'),
 'health',jsonb_build_object('mailMode','sink','mailSinkCount',(select count(*) from app_private.fn_mail_sink where event_id=eid),'activeReservations',(select count(*) from app_private.fn_destinations where event_id=eid and state='current'),'expiredReservations',(select count(*) from app_private.fn_destinations where event_id=eid and state='current' and lease_until<app_private.fn_now(eid)),'syntheticWalkFixture',exists(select 1 from app_private.fn_walk_edges where event_id=eid and source='synthetic-fixture'),'engine','deterministic-v1','hardwareEnabled',false)); end if;
 -- Authoritative event totals are separate from bounded personal-data DTOs.
 if is_admin or app_private.fn_can(eid,'payments_manage',actor) then
  select jsonb_build_object('registrations',count(*),'paid',count(*)filter(where payment_status='paid')) into totals from app_private.fn_registrations where event_id=eid and status<>'archived';
 end if;
 if is_admin then
  select totals||jsonb_build_object('started',count(*)filter(where p.started_at is not null),'completed',count(*)filter(where p.state='finished')) into totals from app_private.fn_registrations r join app_private.fn_members m on m.event_id=r.event_id and m.registration_id=r.id join app_private.fn_parties p on p.event_id=m.event_id and p.id=m.party_id where r.event_id=eid and r.status<>'archived';
 end if;
 if is_zone_admin then totals:=totals||jsonb_build_object('openZones',(select count(*) from app_private.fn_zones z join app_private.fn_events f on f.event_id=z.event_id and f.run_id=z.run_id where z.event_id=eid and z.review_status='approved' and app_private.fn_zone_status(z.id) in('open','busy'))); end if;
 if app_private.fn_can(eid,'live_support',actor) then totals:=totals||jsonb_build_object('openIncidents',(select count(*) from app_private.fn_incidents where event_id=eid and status='open')); end if;
 if totals<>'{}'::jsonb then result:=result||jsonb_build_object('metrics',totals); end if;
 return result;
end $$;
create function app_private.fn_seed(p_event uuid,p_actor uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=p_actor; eid uuid:=p_event; f app_private.fn_events; tok text; result jsonb; oid uuid; rid uuid; pid uuid; x record;
begin
 select * into f from app_private.fn_events where event_id=eid and environment='staging' and is_test for update;
 if f.event_id is null or not app_private.has_capability(eid,'event_admin',actor) then raise exception 'TEST_ADMIN_REQUIRED' using errcode='42501'; end if;
  if f.seed_version>0 then raise exception 'RESET_BEFORE_RESEED' using errcode='22023'; end if;
  tok:=encode(extensions.hmac(eid::text||':start:'||f.run_id::text||':1',encode(f.qr_secret,'hex'),'sha256'),'hex'); update app_private.fn_events set seed_version=1,start_token_hash=extensions.digest(tok,'sha256'),test_clock=(select (local_date+time '17:05') at time zone timezone from app_private.events where id=eid),version=version+1 where event_id=eid;
  result:=jsonb_build_object('startCode',tok,'zoneCodes','[]'::jsonb,'scenarioVersion',1);
  for x in select * from (values ('Oogstdorp · Duinpad','Duinpad','finale',1,100,true,false,false,52.0949,4.2593),('De Koperen Ketel','Duinpad 12','candy',0,10,true,false,false,52.0952,4.2598),('Het Wortelhuis','Duinpad 18','fright',2,8,true,false,false,52.0955,4.2602),('De Kraaienhof','Duinpad 24','fright',4,6,false,true,true,52.0958,4.2607),('De Stille Tuin','Duinpad 30','fright',1,8,true,false,false,52.0961,4.2611)) as v(name,address,type,intensity,capacity,stepfree,smoke,strobes,lat,lng) loop
   tok:=encode(extensions.gen_random_bytes(24),'hex');
   insert into app_private.fn_zones(event_id,name,address,type,intensity,capacity,step_free,smoke,strobes,opens_at,closes_at,status,review_status,description,latitude,longitude,token_hash,synthetic,run_id)
    select eid,x.name,x.address,x.type,x.intensity,x.capacity,x.stepfree,x.smoke,x.strobes,(local_date+time '13:00') at time zone timezone,(local_date+time '21:30') at time zone timezone,'open','approved','Synthetische testlocatie; wandelverbindingen vereisen verificatie door de organisatie.',x.lat,x.lng,extensions.digest(tok,'sha256'),true,f.run_id from app_private.events where id=eid returning id into oid;
   tok:=encode(extensions.hmac(oid::text||':1',encode(f.qr_secret,'hex'),'sha256'),'hex'); update app_private.fn_zones set token_hash=extensions.digest(tok,'sha256') where id=oid;
   result:=jsonb_set(result,'{zoneCodes}',(result->'zoneCodes')||jsonb_build_array(jsonb_build_object('zoneId',oid,'name',x.name,'code',tok)));
  end loop;
  for x in select * from (values ('Testgezin Duin',2,2,2,'lantern'),('Testgezin Koper',1,2,1,'lantern'),('Testgezin Kraai',2,1,5,'roots'),('Testgezin Lantaarn',1,1,3,'roots'))v(label,adults,children,intensity,route_type) loop
   insert into app_private.fn_registrations(event_id,label,route_type,adults,children,max_intensity,amount_cents,run_id,synthetic)
   values(eid,x.label,x.route_type,x.adults,x.children,x.intensity,(x.adults+x.children)*f.price_cents,f.run_id,true) returning id into rid;
   insert into app_private.fn_parties(event_id,run_id) values(eid,f.run_id) returning id into pid;
   insert into app_private.fn_members values(eid,pid,rid,now());
  end loop;
  -- No invented walking geometry is accepted as a verified route. Operations may
  -- approve measured walking links through admin.walk.verify after site review.
  insert into app_private.fn_activities(event_id,name,starts_at,ends_at,capacity,run_id)
   select eid,v.name,(e.local_date+v.starts) at time zone e.timezone,(e.local_date+v.ends) at time zone e.timezone,30,f.run_id from app_private.events e cross join (values('Het Lantaarnatelier',time '14:00',time '14:45'),('Wortelrakkers maken',time '15:00',time '15:45'))v(name,starts,ends) where e.id=eid;
  insert into app_private.fn_quests(event_id,id,title,question,type,answer_hash) values
   (eid,'riddle-1','De kroon','Waar verbergt de Pompoenkoning het Duinlicht?','riddle',extensions.digest('kroon','sha256')),
   (eid,'riddle-2','Het Duinlicht','Waar brengen we de Lichtvonken terug?','riddle',extensions.digest('lichtbaken','sha256')),
   (eid,'riddle-3','De bode','Wie brengt de berichten van de koning?','riddle',extensions.digest('kraaienbode','sha256')),
   (eid,'game-1','Kroonsymbolen','Onthoud de volgorde van de vier kroonsymbolen.','game',extensions.digest('kroon|veer|lantaarn|maan','sha256')),
   (eid,'game-2','Lantaarnkleuren','Ontsteek de lantaarns in de juiste kleurvolgorde.','game',extensions.digest('amber|groen|wit','sha256')),
   (eid,'game-3','Kraaienparen','Zoek de drie gelijke paren.','game',extensions.digest('kroon:kroon|veer:veer|lantaarn:lantaarn','sha256')) on conflict(event_id,id) do update set question=excluded.question,answer_hash=excluded.answer_hash;

 return result;
end $$;
create function app_private.fn_walk_geometry_valid(p_geometry jsonb) returns boolean language plpgsql immutable set search_path='' as $$
declare point jsonb; n integer;
begin
 if p_geometry is null or p_geometry='null'::jsonb then return true; end if;
 if jsonb_typeof(p_geometry) is distinct from 'object' or p_geometry->>'type' is distinct from 'LineString' or jsonb_typeof(p_geometry->'coordinates') is distinct from 'array' then return false; end if;
 n:=jsonb_array_length(p_geometry->'coordinates'); if n<2 or n>5000 then return false; end if;
 for point in select value from jsonb_array_elements(p_geometry->'coordinates') loop
  if jsonb_typeof(point) is distinct from 'array' then return false; end if;
  if jsonb_array_length(point)<>2 or jsonb_typeof(point->0) is distinct from 'number' or jsonb_typeof(point->1) is distinct from 'number' then return false; end if;
  if (point->>0)::numeric not between 4.23 and 4.30 or (point->>1)::numeric not between 52.07 and 52.12 then return false; end if;
 end loop;
 return true;
end $$;
create function api.frightnight_command(p_slug text,p_command text,p_payload jsonb,p_key uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); eid uuid; f app_private.fn_events; r app_private.fn_registrations; p app_private.fn_parties; d app_private.fn_destinations; z app_private.fn_zones; other app_private.fn_registrations; target app_private.fn_parties;
 rid uuid; pid uuid; oid uuid; did uuid; tok text; request_digest bytea; previous app_private.fn_receipts; result jsonb:='{}'; response jsonb; now_business timestamptz; pref jsonb; cnt integer; a app_private.fn_activities; invitation app_private.fn_invites; endtime timestamptz; starttime timestamptz; q app_private.fn_quests; adult_invitation app_private.fn_registration_invites; announcement app_private.fn_announcements; message_audience text; message_target uuid; quoted boolean:=false; x record;
begin
 if actor is null then raise exception 'LOGIN_REQUIRED' using errcode='42501'; end if;
 if p_key is null or p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'INVALID_COMMAND' using errcode='22023'; end if;
 select e.id into eid from app_private.events e join app_private.fn_events fe on fe.event_id=e.id where e.slug=p_slug and fe.environment='staging' and fe.is_test;
 if eid is null then raise exception 'EDITION_NOT_AVAILABLE' using errcode='22023'; end if;
 select * into f from app_private.fn_events where event_id=eid for update;
 request_digest:=extensions.digest(p_command||':'||p_payload::text,'sha256');
 rid:=app_private.fn_registration(eid,actor);
 if (p_command like 'admin.%' or p_command='help.reply') and not(app_private.has_capability(eid,'event_admin',actor)
  or (p_command like 'admin.zone.%' and app_private.fn_can(eid,'portals_manage',actor))
  or (p_command in('admin.incident.resolve','help.reply') and app_private.fn_can(eid,'live_support',actor))
  or (p_command='admin.activity.checkin' and exists(select 1 from app_private.fn_activity_staff fs join app_private.fn_bookings fb on fb.event_id=fs.event_id and fb.activity_id=fs.activity_id where fs.event_id=eid and fs.user_id=actor and fb.id=(p_payload->>'bookingId')::uuid))
  or (p_command='admin.announcement' and app_private.fn_can(eid,'content_manage',actor))) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_command like 'test.%' and not app_private.has_capability(eid,'event_admin',actor) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_command='qr.issue' then
  if p_payload->>'zoneId' is null then
   if not app_private.has_capability(eid,'event_admin',actor) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  elsif not exists(select 1 from app_private.fn_zones zz where zz.event_id=eid and zz.id=(p_payload->>'zoneId')::uuid and (zz.owner_id=actor or app_private.fn_can(eid,'portals_manage',actor))) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 end if;
 select * into previous from app_private.fn_receipts where event_id=eid and actor_id=actor and command_key=p_key;
 if found then if previous.result#>>'{snapshot,registration,id}' is distinct from rid::text then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if; if previous.request_hash<>request_digest then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='40001'; end if; return jsonb_set(previous.result,'{snapshot}',api.frightnight_snapshot(p_slug))||jsonb_build_object('ok',true); end if;
 now_business:=app_private.fn_now(eid); rid:=app_private.fn_registration(eid,actor);
 select * into r from app_private.fn_registrations where id=rid;
 select party_id into pid from app_private.fn_members where event_id=eid and registration_id=rid;
 select * into p from app_private.fn_parties where id=pid;
 if (p_command like 'admin.%' or p_command='help.reply') and not(app_private.has_capability(eid,'event_admin',actor)
  or (p_command like 'admin.zone.%' and app_private.fn_can(eid,'portals_manage',actor))
  or (p_command in('admin.incident.resolve','help.reply') and app_private.fn_can(eid,'live_support',actor))
  or (p_command='admin.activity.checkin' and exists(select 1 from app_private.fn_activity_staff fs join app_private.fn_bookings fb on fb.event_id=fs.event_id and fb.activity_id=fs.activity_id where fs.event_id=eid and fs.user_id=actor and fb.id=(p_payload->>'bookingId')::uuid))
  or (p_command='admin.announcement' and app_private.fn_can(eid,'content_manage',actor))) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_command like 'test.%' and not app_private.has_capability(eid,'event_admin',actor) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if f.closed and p_command in('registration.save','journey.start','party.join','activity.book') then raise exception 'EDITION_CLOSED' using errcode='22023'; end if;
 if p_command='registration.save' then
  pref:=app_private.fn_party_preferences(pid);
  quoted:=exists(select 1 from app_private.fn_orders where event_id=eid and registration_id=rid);
  if r.id is not null and (r.payment_status='paid' or p.started_at is not null) and ((p_payload->>'adults')::integer<>r.adults or (p_payload->>'children')::integer<>r.children or p_payload->>'routeType'<>r.route_type) then raise exception 'PAID_PLACES_REQUIRE_SUPPORT' using errcode='22023'; end if;
  -- Every issued quote remains binding even after failure/expiry: a provider
  -- may still confirm that old attempt. Preferences/start/contact stay editable.
  if quoted and ((p_payload->>'adults')::integer is distinct from r.adults or (p_payload->>'children')::integer is distinct from r.children or p_payload->>'routeType' is distinct from r.route_type) then raise exception 'PAYMENT_QUOTE_LOCKED' using errcode='22023'; end if;
  if p_payload?'expectedVersion' and r.id is not null and (p_payload->>'expectedVersion')::integer<>r.version then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
  if r.id is null then
   if (p_payload->>'consent')::boolean is distinct from true or p_payload->>'termsVersion' is distinct from '2027-test-v1' then raise exception 'REGISTRATION_CONSENT_REQUIRED' using errcode='22023'; end if;
   insert into app_private.households(label,primary_contact_user_id) values(trim(p_payload->>'label'),actor) returning id into oid;
   insert into app_private.household_members(household_id,user_id,relation_role) values(oid,actor,'owner');
   insert into app_private.fn_registrations(event_id,owner_id,household_id,terms_version,consented_at,consent_actor,label,route_type,adults,children,max_intensity,avoid_smoke,avoid_strobes,step_free,start_slot,amount_cents,run_id)
   values(eid,actor,oid,'2027-test-v1',now(),actor,trim(p_payload->>'label'),p_payload->>'routeType',(p_payload->>'adults')::integer,(p_payload->>'children')::integer,(p_payload->>'maxIntensity')::integer,coalesce((p_payload->>'avoidSmoke')::boolean,false),coalesce((p_payload->>'avoidStrobes')::boolean,false),coalesce((p_payload->>'stepFree')::boolean,false),nullif(p_payload->>'startSlot','')::timestamptz,((p_payload->>'adults')::integer+(p_payload->>'children')::integer)*f.price_cents,f.run_id) returning id into rid;
   insert into app_private.fn_parties(event_id,run_id) values(eid,f.run_id) returning id into pid;
   insert into app_private.fn_members values(eid,pid,rid,now());
  else
   if (p_payload->>'consent')::boolean=true and p_payload->>'termsVersion'='2027-test-v1' then update app_private.fn_registrations set terms_version='2027-test-v1',consented_at=coalesce(consented_at,now()),consent_actor=coalesce(consent_actor,actor) where id=rid; end if;
   update app_private.fn_registrations set label=trim(p_payload->>'label'),route_type=p_payload->>'routeType',adults=(p_payload->>'adults')::integer,children=(p_payload->>'children')::integer,max_intensity=(p_payload->>'maxIntensity')::integer,
    avoid_smoke=coalesce((p_payload->>'avoidSmoke')::boolean,false),avoid_strobes=coalesce((p_payload->>'avoidStrobes')::boolean,false),step_free=coalesce((p_payload->>'stepFree')::boolean,false),start_slot=nullif(p_payload->>'startSlot','')::timestamptz,
    amount_cents=case when quoted or payment_status='paid' then amount_cents else ((p_payload->>'adults')::integer+(p_payload->>'children')::integer)*f.price_cents end,version=version+1 where id=rid;
  end if;
  select * into r from app_private.fn_registrations where id=rid;
  if r.start_slot is null then
   update app_private.fn_registrations set start_slot=(select min(ss.starts_at) from app_private.fn_start_slots ss where ss.event_id=eid and ss.route_type=r.route_type and app_private.fn_slot_available(eid,ss.starts_at,rid)>=r.adults+r.children) where id=rid returning * into r;
  end if;
  if r.start_slot is not null and coalesce(app_private.fn_slot_available(eid,r.start_slot,rid),-1)<r.adults+r.children then raise exception 'START_SLOT_FULL' using errcode='22023'; end if;
  if r.start_slot is not null then
   select (e.local_date+case when r.route_type='lantern' then time '17:00' else time '18:30' end) at time zone e.timezone,(e.local_date+case when r.route_type='lantern' then time '18:30' else time '21:00' end) at time zone e.timezone into starttime,endtime from app_private.events e where e.id=eid;
   if r.start_slot<starttime or r.start_slot>=endtime then raise exception 'START_SLOT_OUTSIDE_WINDOW' using errcode='22023'; end if;
  end if;
  if r.payment_status='paid' and r.status='draft' and r.start_slot is not null and exists(select 1 from app_private.fn_orders where event_id=eid and registration_id=rid and status='paid' and amount_cents=r.amount_cents) and not exists(select 1 from app_private.fn_orders where event_id=eid and registration_id=rid and ((status='paid' and amount_cents<>r.amount_cents) or status='refunded')) then update app_private.fn_registrations set status='active',version=version+1 where id=rid; end if;
  if p.started_at is not null and p.state in('walking','waiting') and (pref-'members') is distinct from (app_private.fn_party_preferences(pid)-'members') then update app_private.fn_destinations set state='released' where party_id=pid and state='current'; update app_private.fn_parties set version=version+1 where id=pid; perform app_private.fn_choose(eid,pid); end if;
  result:=jsonb_build_object('registrationId',rid);
 elsif p_command='preferences.save' then
  if rid is null then raise exception 'REGISTRATION_REQUIRED' using errcode='42501'; end if;
  update app_private.fn_registrations set max_intensity=(p_payload->>'maxIntensity')::integer,avoid_smoke=coalesce((p_payload->>'avoidSmoke')::boolean,false),avoid_strobes=coalesce((p_payload->>'avoidStrobes')::boolean,false),step_free=coalesce((p_payload->>'stepFree')::boolean,false),version=version+1 where id=rid;
  if p.state in('walking','waiting') then update app_private.fn_destinations set state='released' where party_id=pid and state='current'; update app_private.fn_parties set version=version+1 where id=pid; perform app_private.fn_choose(eid,pid); end if;
 elsif p_command in('journey.start','journey.complete','journey.skip','journey.pause','journey.resume','journey.finish') then
  if rid is null or r.status<>'active' or r.payment_status<>'paid' or exists(select 1 from app_private.fn_members mm join app_private.fn_registrations rr on rr.id=mm.registration_id where mm.party_id=pid and (rr.status<>'active' or rr.payment_status<>'paid')) then raise exception 'PAID_REGISTRATION_REQUIRED' using errcode='42501'; end if;
  if (p_payload->>'expectedVersion')::integer is distinct from p.version then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
  select (e.local_date+case when r.route_type='lantern' then time '18:30' else time '21:00' end) at time zone e.timezone into endtime from app_private.events e where e.id=eid;
  if f.paused and p_command not in('journey.pause','journey.finish') then raise exception 'EVENT_PAUSED' using errcode='22023'; end if;
  if p.state in('finished','merged','archived') then raise exception 'JOURNEY_FINISHED' using errcode='22023'; end if;
  select * into d from app_private.fn_destinations where party_id=pid and state='current';
  if p_command='journey.start' then
   if p.started_at is not null then raise exception 'ALREADY_STARTED' using errcode='40001'; end if;
   select (e.local_date+case when r.route_type='lantern' then time '17:00' else time '18:30' end) at time zone e.timezone,(e.local_date+case when r.route_type='lantern' then time '18:30' else time '21:00' end) at time zone e.timezone into starttime,endtime from app_private.events e where e.id=eid;
   if now_business<starttime or now_business>=endtime then raise exception 'OUTSIDE_ROUTE_WINDOW' using errcode='22023'; end if;
   if f.qr_required and (f.start_token_hash is null or f.start_token_hash is distinct from extensions.digest(coalesce(p_payload->>'code',''),'sha256')) then raise exception 'INVALID_START_CODE' using errcode='22023'; end if;
   update app_private.fn_parties set started_at=now_business,version=version+1 where id=pid; perform app_private.fn_choose(eid,pid);
  elsif p_command='journey.pause' then
   update app_private.fn_destinations set state='released' where party_id=pid and state='current'; update app_private.fn_parties set state='paused',version=version+1,reason='Jullie tocht is gepauzeerd. Hervat wanneer jullie weer willen lopen.' where id=pid;
  elsif p_command in('journey.resume','journey.finish') then
   if p.started_at is null then raise exception 'START_REQUIRED' using errcode='22023'; end if;
   update app_private.fn_destinations set state='released' where party_id=pid and state='current'; update app_private.fn_parties set version=version+1 where id=pid; perform app_private.fn_choose(eid,pid,p_command='journey.finish');
  else
   if d.id is null or d.id is distinct from (p_payload->>'destinationId')::uuid then raise exception 'DESTINATION_CONFLICT' using errcode='40001'; end if;
   if p.state<>'walking' then raise exception 'JOURNEY_NOT_WALKING' using errcode='22023'; end if;
   select * into z from app_private.fn_zones where id=d.zone_id;
   if p_command='journey.complete' then
    if z.type<>'finale' and now_business>=endtime then raise exception 'ROUTE_WINDOW_END_RESUME' using errcode='40001'; end if;
    if d.lease_until<now_business then raise exception 'RESERVATION_EXPIRED_RESUME' using errcode='40001'; end if;
    if app_private.fn_zone_status(z.id) not in('open','busy') or z.review_status<>'approved' or (z.type<>'finale' and (now_business<z.opens_at or now_business>z.closes_at)) then raise exception 'ZONE_UNAVAILABLE_RESUME' using errcode='40001'; end if;
    if f.qr_required and z.token_hash is distinct from extensions.digest(coalesce(p_payload->>'code',''),'sha256') then raise exception 'INVALID_ZONE_CODE' using errcode='22023'; end if;
    insert into app_private.fn_visits(event_id,registration_id,destination_id,zone_id,method,completed_at) select eid,m.registration_id,d.id,z.id,case when f.qr_required then 'qr' else 'released' end,now_business from app_private.fn_members m where m.party_id=pid on conflict do nothing;
    insert into app_private.fn_awards(event_id,registration_id,award_key) select eid,m.registration_id,'visit:'||z.id from app_private.fn_members m where m.party_id=pid on conflict do nothing;
    update app_private.fn_destinations set state='visited',lease_until=greatest(now_business+make_interval(mins=>z.visit_minutes),arrival_at+interval '1 second') where id=d.id;
    if z.type='finale' then update app_private.fn_parties set state='finished',finished_at=now_business,version=version+1 where id=pid;
     insert into app_private.fn_notifications(event_id,registration_id,title,message,dedupe_key) select eid,m.registration_id,'Het Duinlicht is terug!','Bedankt voor jullie tocht. Je Nachtpas bewaart jullie herinneringen.','journey-finished' from app_private.fn_members m where m.party_id=pid on conflict do nothing;
    else update app_private.fn_parties set version=version+1 where id=pid; perform app_private.fn_choose(eid,pid); end if;
   else
    if z.type='finale' then raise exception 'USE_QUIET_FINALE' using errcode='22023'; end if;
    update app_private.fn_destinations set state='skipped' where id=d.id; update app_private.fn_parties set version=version+1 where id=pid; perform app_private.fn_choose(eid,pid);
   end if;
  end if;
 elsif p_command='registration.invite' then
  if rid is null or r.owner_id<>actor then raise exception 'REGISTRATION_OWNER_REQUIRED' using errcode='42501'; end if;
  tok:=encode(extensions.gen_random_bytes(24),'hex');
  insert into app_private.fn_registration_invites(event_id,registration_id,invited_by,token_hash,expires_at) values(eid,rid,actor,extensions.digest(tok,'sha256'),now()+interval '24 hours');
  result:=jsonb_build_object('token',tok,'expiresAt',now()+interval '24 hours','purpose','shared-registration');
 elsif p_command='registration.accept' then
  if (p_payload->>'consent')::boolean is distinct from true then raise exception 'EXPLICIT_CONSENT_REQUIRED' using errcode='42501'; end if;
  select * into adult_invitation from app_private.fn_registration_invites where event_id=eid and token_hash=extensions.digest(coalesce(p_payload->>'token',''),'sha256') and expires_at>now() and consumed_by is null and revoked_at is null for update;
  if adult_invitation.id is null then raise exception 'INVITATION_INVALID' using errcode='22023'; end if;
  if rid is not null and rid<>adult_invitation.registration_id then raise exception 'EXISTING_REGISTRATION_REQUIRES_SUPPORT' using errcode='22023'; end if;
  select * into other from app_private.fn_registrations where event_id=eid and id=adult_invitation.registration_id;
  if other.household_id is null or other.status in('archived','cancelled') then raise exception 'INVITATION_INVALID' using errcode='22023'; end if;
  if not app_private.is_household_member(other.household_id,actor) then insert into app_private.household_members(household_id,user_id,relation_role) values(other.household_id,actor,'adult'); end if;
  update app_private.fn_registration_invites set consumed_by=actor where id=adult_invitation.id;
  result:=jsonb_build_object('registrationId',other.id,'purpose','shared-registration');
 elsif p_command='contact.save' then
  if rid is null or r.owner_id is distinct from actor or (p_payload->>'registrationId' is not null and (p_payload->>'registrationId')::uuid is distinct from rid) then raise exception 'CONTACT_OWNER_REQUIRED' using errcode='42501'; end if;
  if (p_payload->>'expectedVersion')::integer is distinct from r.version then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
  if length(trim(coalesce(p_payload->>'contactName',''))) not between 1 and 120 or (p_payload?'contactPhone' and (length(trim(coalesce(p_payload->>'contactPhone','')))>25 or trim(coalesce(p_payload->>'contactPhone',''))!~'^[0-9+(). /-]*$')) then raise exception 'INVALID_CONTACT' using errcode='22023'; end if;
  update app_private.fn_registrations set contact_name=trim(p_payload->>'contactName'),contact_phone=case when p_payload?'contactPhone' then nullif(trim(p_payload->>'contactPhone'),'') else contact_phone end,version=version+1 where event_id=eid and id=rid and owner_id=actor returning version into cnt;
  result:=jsonb_build_object('registrationId',rid,'version',cnt);
 elsif p_command='registration.revoke' then
  if rid is null or r.owner_id<>actor or (p_payload->>'userId')::uuid=r.owner_id then raise exception 'REGISTRATION_OWNER_REQUIRED' using errcode='42501'; end if;
  update app_private.household_members set revoked_at=now(),revoked_by=actor where household_id=r.household_id and user_id=(p_payload->>'userId')::uuid and revoked_at is null;
  update app_private.fn_registration_invites set revoked_at=now() where event_id=eid and registration_id=rid and consumed_by=(p_payload->>'userId')::uuid;
 elsif p_command='party.invite' then
  if rid is null or r.payment_status<>'paid' or r.status<>'active' or p.id is null or p.event_id<>eid or p.state in('finished','merged','archived') then raise exception 'PAID_REGISTRATION_REQUIRED' using errcode='42501'; end if;
  if not exists(select 1 from app_private.fn_members where party_id=pid and event_id=eid) or exists(select 1 from app_private.fn_members m left join app_private.fn_registrations rg on rg.id=m.registration_id and rg.event_id=eid where m.party_id=pid and (m.event_id<>eid or rg.id is null or rg.status<>'active' or rg.payment_status<>'paid' or rg.route_type<>r.route_type)) then raise exception 'SAME_PAID_ROUTE_REQUIRED' using errcode='22023'; end if;
  tok:=encode(extensions.gen_random_bytes(24),'hex'); insert into app_private.fn_invites(event_id,party_id,token_hash,expires_at) values(eid,pid,extensions.digest(tok,'sha256'),now()+interval '24 hours'); result:=jsonb_build_object('token',tok,'expiresAt',now()+interval '24 hours');
 elsif p_command='party.join' then
  if rid is null or r.payment_status<>'paid' or r.status<>'active' or p.id is null or p.event_id<>eid or p.state in('finished','merged','archived') or (p_payload->>'consent')::boolean is distinct from true then raise exception 'PAID_CONSENT_REQUIRED' using errcode='42501'; end if;
  select * into invitation from app_private.fn_invites where event_id=eid and token_hash=extensions.digest(coalesce(p_payload->>'token',''),'sha256') and revoked_at is null and consumed_by is null and expires_at>now() for update;
  if invitation.id is null or invitation.party_id=pid then raise exception 'INVITATION_INVALID' using errcode='22023'; end if;
  select * into target from app_private.fn_parties where id=invitation.party_id and event_id=eid for update;
  if target.id is null or target.state in('finished','merged','archived') then raise exception 'INVITATION_INVALID' using errcode='22023'; end if;
  -- Validate both complete parties before releasing claims, moving members or
  -- consuming the invitation. The event lock also serializes payment refunds.
  if not exists(select 1 from app_private.fn_members where party_id=target.id and event_id=eid) or exists(select 1 from app_private.fn_members m left join app_private.fn_registrations rg on rg.id=m.registration_id and rg.event_id=eid where m.party_id in(pid,target.id) and (m.event_id<>eid or rg.id is null or rg.status<>'active' or rg.payment_status<>'paid' or rg.route_type<>r.route_type)) then raise exception 'SAME_PAID_ROUTE_REQUIRED' using errcode='22023'; end if;
  pref:=app_private.fn_party_preferences(pid); result:=app_private.fn_party_preferences(target.id);
  if (pref->>'persons')::integer+(result->>'persons')::integer>f.max_party then raise exception 'PARTY_TOO_LARGE' using errcode='22023'; end if;
  update app_private.fn_destinations set state='released' where party_id in(pid,target.id) and state='current';
  update app_private.fn_members set party_id=target.id where party_id=pid;
  update app_private.fn_parties set state='merged',version=version+1,membership_version=membership_version+1 where id=pid;
  update app_private.fn_parties set membership_version=membership_version+1,version=version+1,started_at=coalesce(started_at,p.started_at) where id=target.id;
  update app_private.fn_invites set consumed_by=actor where id=invitation.id;
  if target.started_at is not null or p.started_at is not null then perform app_private.fn_choose(eid,target.id); end if; result:=jsonb_build_object('partyId',target.id);
 elsif p_command='party.leave' then
  if rid is null or p.state in('finished','merged','archived') then raise exception 'ACTIVE_PARTY_REQUIRED' using errcode='42501'; end if;
  select count(*) into cnt from app_private.fn_members where party_id=pid;
  if cnt<=1 then raise exception 'ALREADY_INDEPENDENT' using errcode='22023'; end if;
  update app_private.fn_destinations set state='released' where party_id=pid and state='current';
  insert into app_private.fn_parties(event_id,run_id,started_at) values(eid,f.run_id,p.started_at) returning id into oid;
  update app_private.fn_members set party_id=oid where registration_id=rid and event_id=eid;
  update app_private.fn_parties set membership_version=membership_version+1,version=version+1 where id=pid;
  if p.started_at is not null then perform app_private.fn_choose(eid,pid); perform app_private.fn_choose(eid,oid); end if; result:=jsonb_build_object('partyId',oid);
 elsif p_command in('activity.book','activity.cancel') then
  if rid is null or (p_command='activity.book' and (r.payment_status<>'paid' or r.status<>'active')) then raise exception 'PAID_REGISTRATION_REQUIRED' using errcode='42501'; end if;
  select * into a from app_private.fn_activities where event_id=eid and id=(p_payload->>'activityId')::uuid and run_id=f.run_id for update;
  if a.id is null then raise exception 'ACTIVITY_NOT_FOUND' using errcode='22023'; end if;
  if p_command='activity.book' then
   if a.starts_at<=now_business then raise exception 'ACTIVITY_STARTED' using errcode='22023'; end if;
   if exists(select 1 from app_private.fn_bookings b where b.registration_id=rid and b.activity_id=a.id and b.status in('booked','checked_in')) then result:=jsonb_build_object('alreadyBooked',true);
   else
    select coalesce(sum(seats),0) into cnt from app_private.fn_bookings where activity_id=a.id and status in('booked','checked_in');
    if cnt+r.adults+r.children>a.capacity then raise exception 'ACTIVITY_FULL' using errcode='22023'; end if;
    insert into app_private.fn_bookings(event_id,activity_id,registration_id,seats) values(eid,a.id,rid,r.adults+r.children) on conflict(event_id,registration_id,activity_id) do update set status='booked',seats=excluded.seats;
   end if;
  else update app_private.fn_bookings set status='cancelled' where event_id=eid and registration_id=rid and activity_id=a.id and status='booked'; end if;
 elsif p_command='quest.answer' then
  if rid is null or r.payment_status<>'paid' or r.status<>'active' then raise exception 'PAID_REGISTRATION_REQUIRED' using errcode='42501'; end if;
  select * into q from app_private.fn_quests where event_id=eid and id=p_payload->>'questId';
  if q.id is null or q.answer_hash is distinct from extensions.digest(lower(trim(coalesce(p_payload->>'answer',''))),'sha256') then raise exception 'ANSWER_INCORRECT' using errcode='22023'; end if;
  insert into app_private.fn_awards(event_id,registration_id,award_key) values(eid,rid,'quest:'||q.id) on conflict do nothing;
 elsif p_command='beacon.complete' then
  if rid is null or r.payment_status<>'paid' or r.status<>'active' then raise exception 'PAID_REGISTRATION_REQUIRED' using errcode='42501'; end if;
  if p.state<>'finished' then raise exception 'FINALE_REQUIRED' using errcode='22023'; end if;
  insert into app_private.fn_awards(event_id,registration_id,award_key) values(eid,rid,'beacon') on conflict do nothing;
 elsif p_command='zone.apply' then
  if p_payload->>'type' not in('candy','fright') then raise exception 'INVALID_ZONE_TYPE' using errcode='22023'; end if;
  tok:=encode(extensions.gen_random_bytes(24),'hex');
  if p_payload->>'zoneId' is not null then
   select * into z from app_private.fn_zones where event_id=eid and id=(p_payload->>'zoneId')::uuid;
   if z.id is null or not(coalesce(z.owner_id=actor,false) or app_private.fn_can(eid,'portals_manage',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   if p_payload?'expectedVersion' and (p_payload->>'expectedVersion')::integer is distinct from z.version then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
   if (select coalesce(sum(persons),0) from app_private.fn_destinations where zone_id=z.id and (state='current' or (state='visited' and lease_until>now_business)))>(p_payload->>'capacity')::integer then raise exception 'CAPACITY_BELOW_RESERVATIONS' using errcode='22023'; end if;
   update app_private.fn_zones set location_confirmed_at=null,name=trim(p_payload->>'name'),address=trim(p_payload->>'address'),type=p_payload->>'type',intensity=case when p_payload->>'type'='candy' then 0 else (p_payload->>'intensity')::integer end,
    capacity=(p_payload->>'capacity')::integer,opens_at=(p_payload->>'opensAt')::timestamptz,closes_at=(p_payload->>'closesAt')::timestamptz,smoke=coalesce((p_payload->>'smoke')::boolean,false),strobes=coalesce((p_payload->>'strobes')::boolean,false),step_free=coalesce((p_payload->>'stepFree')::boolean,false),description=coalesce(p_payload->>'description',''),review_status='submitted',status='closed',version=version+1 where id=z.id;
   oid:=z.id;
  else
  insert into app_private.fn_zones(event_id,owner_id,name,address,type,intensity,capacity,opens_at,closes_at,smoke,strobes,step_free,description,token_hash,run_id)
   values(eid,actor,trim(p_payload->>'name'),trim(p_payload->>'address'),p_payload->>'type',case when p_payload->>'type'='candy' then 0 else (p_payload->>'intensity')::integer end,(p_payload->>'capacity')::integer,(p_payload->>'opensAt')::timestamptz,(p_payload->>'closesAt')::timestamptz,coalesce((p_payload->>'smoke')::boolean,false),coalesce((p_payload->>'strobes')::boolean,false),coalesce((p_payload->>'stepFree')::boolean,false),coalesce(p_payload->>'description',''),extensions.digest(tok,'sha256'),f.run_id) returning id into oid;
  end if;
  result:=jsonb_build_object('zoneId',oid,'message','Aanmelding ontvangen. De organisatie controleert adres en toegankelijkheid voordat deze zone bezoekers krijgt.');
 elsif p_command in('zone.status','zone.qr','zone.profile') then
  select * into z from app_private.fn_zones where event_id=eid and id=(p_payload->>'zoneId')::uuid for update;
  if z.id is null or not(coalesce(z.owner_id=actor,false) or app_private.fn_can(eid,'portals_manage',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if p_command='zone.qr' then
   if z.review_status<>'approved' then raise exception 'APPROVAL_REQUIRED' using errcode='22023'; end if;
   tok:=encode(extensions.hmac(z.id::text||':'||(z.token_version+1)::text,encode(f.qr_secret,'hex'),'sha256'),'hex'); update app_private.fn_zones set token_hash=extensions.digest(tok,'sha256'),token_version=token_version+1,version=version+1 where id=z.id; result:=jsonb_build_object('code',tok,'zoneId',z.id);
  else
   if (p_payload->>'expectedVersion')::integer is distinct from z.version then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
   if p_command='zone.status' then
    if z.review_status<>'approved' then raise exception 'APPROVAL_REQUIRED' using errcode='22023'; end if;
    if p_payload->>'status'='paused' and p_payload->>'pauseUntil' is not null and (p_payload->>'pauseUntil')::timestamptz<=now_business then raise exception 'PAUSE_END_MUST_BE_FUTURE' using errcode='22023'; end if;
    update app_private.fn_zones set status=p_payload->>'status',pause_until=case when p_payload->>'status'='paused' then nullif(p_payload->>'pauseUntil','')::timestamptz else null end,pause_reason=case when p_payload->>'status'='paused' then nullif(p_payload->>'reason','') else null end,version=version+1 where id=z.id;
   else
    update app_private.fn_zones set name=trim(p_payload->>'name'),description=coalesce(p_payload->>'description',''),capacity=(p_payload->>'capacity')::integer,opens_at=(p_payload->>'opensAt')::timestamptz,closes_at=(p_payload->>'closesAt')::timestamptz,version=version+1 where id=z.id;
    if exists(select 1 from app_private.fn_destinations where zone_id=z.id and (state='current' or (state='visited' and lease_until>now_business)) group by zone_id having sum(persons)>(p_payload->>'capacity')::integer) then raise exception 'CAPACITY_BELOW_RESERVATIONS' using errcode='22023'; end if;
   end if;
  end if;
 elsif p_command in('zone.confirm','zone.contact.confirm','zone.location.confirm') then
  select * into z from app_private.fn_zones where event_id=eid and id=(p_payload->>'zoneId')::uuid;
  if z.id is null or not(coalesce(z.owner_id=actor,false) or app_private.fn_can(eid,'portals_manage',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if (p_payload->>'expectedVersion')::integer is distinct from z.version then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
  if p_command='zone.location.confirm' then
   if (p_payload->>'confirmed')::boolean is distinct from true or (p_payload->>'latitude')::double precision not between 52.07 and 52.12 or (p_payload->>'longitude')::double precision not between 4.23 and 4.30 or p_payload->>'latitude' is null or p_payload->>'longitude' is null then raise exception 'VERIFIED_DUINDORP_LOCATION_REQUIRED' using errcode='22023'; end if;
   update app_private.fn_zones set latitude=(p_payload->>'latitude')::double precision,longitude=(p_payload->>'longitude')::double precision,location_confirmed_at=now(),review_status=case when latitude is distinct from (p_payload->>'latitude')::double precision or longitude is distinct from (p_payload->>'longitude')::double precision then 'submitted' else review_status end,status=case when latitude is distinct from (p_payload->>'latitude')::double precision or longitude is distinct from (p_payload->>'longitude')::double precision then 'closed' else status end,version=version+1 where id=z.id;
  else
   if not exists(select 1 from auth.users where id=z.owner_id and email_confirmed_at is not null) then raise exception 'VERIFIED_OWNER_CONTACT_REQUIRED' using errcode='42501'; end if;
   if (p_payload->>'confirmed')::boolean is distinct from true then raise exception 'EXPLICIT_CONFIRMATION_REQUIRED' using errcode='22023'; end if;
   update app_private.fn_zones set contact_confirmed_at=now(),version=version+1 where id=z.id;
  end if;
 elsif p_command='admin.zone.review' then
  if p_payload->>'decision' not in('approved','rejected') then raise exception 'INVALID_REVIEW' using errcode='22023'; end if;
  if p_payload->>'decision'='approved' and exists(select 1 from app_private.fn_zones where event_id=eid and id=(p_payload->>'zoneId')::uuid and not synthetic and (contact_confirmed_at is null or location_confirmed_at is null)) then raise exception 'ZONE_CONFIRMATION_REQUIRED' using errcode='22023'; end if;
  update app_private.fn_zones set review_status=p_payload->>'decision',status=case when p_payload->>'decision'='approved' then 'open' else 'closed' end,version=version+1 where event_id=eid and id=(p_payload->>'zoneId')::uuid;
  if not found then raise exception 'ZONE_NOT_FOUND' using errcode='22023'; end if;
 elsif p_command='admin.settings' then
  if (p_payload->>'expectedVersion')::integer is distinct from f.version then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
  update app_private.fn_events set qr_required=coalesce((p_payload->>'qrRequired')::boolean,qr_required),paused=coalesce((p_payload->>'paused')::boolean,paused),closed=coalesce((p_payload->>'closed')::boolean,closed),price_cents=coalesce((p_payload->>'priceCents')::integer,price_cents),version=version+1 where event_id=eid;
  if coalesce((p_payload->>'closed')::boolean,false) then
   for x in select id from app_private.fn_parties where event_id=eid and state in('walking','waiting','paused') loop update app_private.fn_destinations set state='released' where party_id=x.id and state='current'; update app_private.fn_parties set version=version+1 where id=x.id; perform app_private.fn_choose(eid,x.id,true); end loop;
  end if;
 elsif p_command='admin.announcement' then
  message_audience:=coalesce(p_payload->>'audience','all');
  if message_audience not in('all','lantern','roots','registration','zone') or length(trim(coalesce(p_payload->>'text',''))) not between 1 and 2000 then raise exception 'INVALID_ANNOUNCEMENT' using errcode='22023'; end if;
  if message_audience='registration' then
   message_target:=(p_payload->>'registrationId')::uuid;
   if p_payload->>'zoneId' is not null or not exists(select 1 from app_private.fn_registrations where event_id=eid and id=message_target and status<>'archived') then raise exception 'ANNOUNCEMENT_TARGET_SCOPE_REQUIRED' using errcode='42501'; end if;
  elsif message_audience='zone' then
   message_target:=(p_payload->>'zoneId')::uuid;
   if p_payload->>'registrationId' is not null or not exists(select 1 from app_private.fn_zones where event_id=eid and id=message_target) then raise exception 'ANNOUNCEMENT_TARGET_SCOPE_REQUIRED' using errcode='42501'; end if;
  elsif p_payload->>'registrationId' is not null or p_payload->>'zoneId' is not null then raise exception 'INVALID_ANNOUNCEMENT_TARGET' using errcode='22023';
  end if;
  if p_payload->>'id' is null then
   if p_payload->>'expectedVersion' is not null then raise exception 'ANNOUNCEMENT_ID_REQUIRED' using errcode='22023'; end if;
   insert into app_private.fn_announcements(event_id,text,audience,target_id) values(eid,trim(p_payload->>'text'),message_audience,message_target) returning * into announcement;
  else
   select * into announcement from app_private.fn_announcements where event_id=eid and id=(p_payload->>'id')::uuid for update;
   if announcement.id is null then raise exception 'ANNOUNCEMENT_SCOPE_REQUIRED' using errcode='42501'; end if;
   if (p_payload->>'expectedVersion')::integer is distinct from announcement.version then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
   update app_private.fn_announcements set text=trim(p_payload->>'text'),audience=message_audience,target_id=message_target,version=version+1,updated_at=now() where event_id=eid and id=announcement.id returning * into announcement;
  end if;
  insert into app_private.fn_audit(event_id,actor_id,action,details) values(eid,actor,'announcement.saved',jsonb_build_object('announcementId',announcement.id,'version',announcement.version,'audience',announcement.audience,'targetId',announcement.target_id,'commandId',p_key));
  result:=jsonb_build_object('announcementId',announcement.id,'version',announcement.version,'audience',announcement.audience);
 elsif p_command='help.submit' then
  insert into app_private.fn_incidents(event_id,actor_id,category,text) values(eid,actor,left(coalesce(p_payload->>'category','help'),50),trim(p_payload->>'text')) returning id into oid; result:=jsonb_build_object('incidentId',oid,'message','Melding ontvangen. Bel bij direct gevaar 112; het hulppunt is op het Duinpad.');
 elsif p_command='admin.incident.resolve' then
  update app_private.fn_incidents set status='resolved' where event_id=eid and id=(p_payload->>'incidentId')::uuid;
 elsif p_command='help.reply' then
  select actor_id into oid from app_private.fn_incidents where event_id=eid and id=(p_payload->>'incidentId')::uuid;
  if oid is null or length(trim(coalesce(p_payload->>'text','')))<1 or length(p_payload->>'text')>2000 then raise exception 'INVALID_REPLY' using errcode='22023'; end if;
  update app_private.fn_incidents set response_text=trim(p_payload->>'text') where event_id=eid and id=(p_payload->>'incidentId')::uuid;
  insert into app_private.fn_notifications(event_id,registration_id,title,message,dedupe_key)
   select eid,rg.id,'Bericht van het hulppunt',trim(p_payload->>'text'),'help:'||p_key from app_private.fn_registrations rg where rg.event_id=eid and rg.owner_id=oid on conflict do nothing;
 elsif p_command='thanks.send' then
  if rid is null or not exists(select 1 from app_private.fn_visits where event_id=eid and registration_id=rid and zone_id=(p_payload->>'zoneId')::uuid) then raise exception 'VISIT_REQUIRED' using errcode='42501'; end if;
  insert into app_private.fn_thanks(event_id,registration_id,zone_id,message) values(eid,rid,(p_payload->>'zoneId')::uuid,trim(p_payload->>'text')) on conflict do nothing;
 elsif p_command='evaluation.save' then
  if rid is null or p.state<>'finished' then raise exception 'FINALE_REQUIRED' using errcode='22023'; end if;
  insert into app_private.fn_evaluations(event_id,registration_id,rating,message) values(eid,rid,(p_payload->>'rating')::integer,coalesce(p_payload->>'text','')) on conflict(event_id,registration_id) do update set rating=excluded.rating,message=excluded.message;
 elsif p_command='zone.photo' then
  select * into z from app_private.fn_zones where event_id=eid and id=(p_payload->>'zoneId')::uuid;
  if z.id is null or not(coalesce(z.owner_id=actor,false) or app_private.fn_can(eid,'portals_manage',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  if (p_payload->>'expectedVersion')::integer is distinct from z.version then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
  if (p_payload->>'path') not like eid::text||'/'||z.id::text||'/'||actor::text||'/%' or not exists(select 1 from storage.objects where bucket_id='frightnight-zone-photos' and name=p_payload->>'path') then raise exception 'INVALID_PHOTO_PATH' using errcode='42501'; end if;
  update app_private.fn_zones set photo_path=p_payload->>'path',version=version+1 where id=z.id;
 elsif p_command='admin.startslot.save' then
  if (select coalesce(sum(adults+children),0) from app_private.fn_registrations where event_id=eid and start_slot=(p_payload->>'startsAt')::timestamptz and status='active' and payment_status='paid')>(p_payload->>'capacity')::integer then raise exception 'CAPACITY_BELOW_BOOKINGS' using errcode='22023'; end if;
  update app_private.fn_start_slots set capacity=(p_payload->>'capacity')::integer where event_id=eid and starts_at=(p_payload->>'startsAt')::timestamptz;
 elsif p_command='admin.activity.save' then
  if p_payload->>'activityId' is null then
   insert into app_private.fn_activities(event_id,name,starts_at,ends_at,capacity,run_id) values(eid,trim(p_payload->>'name'),(p_payload->>'startsAt')::timestamptz,(p_payload->>'endsAt')::timestamptz,(p_payload->>'capacity')::integer,f.run_id);
  else
   if (select coalesce(sum(seats),0) from app_private.fn_bookings where event_id=eid and activity_id=(p_payload->>'activityId')::uuid and status in('booked','checked_in'))>(p_payload->>'capacity')::integer then raise exception 'CAPACITY_BELOW_BOOKINGS' using errcode='22023'; end if;
   update app_private.fn_activities set name=trim(p_payload->>'name'),starts_at=(p_payload->>'startsAt')::timestamptz,ends_at=(p_payload->>'endsAt')::timestamptz,capacity=(p_payload->>'capacity')::integer where event_id=eid and id=(p_payload->>'activityId')::uuid;
  end if;
 elsif p_command='admin.activity.staff' then
  if jsonb_typeof(p_payload->'enabled') is distinct from 'boolean' then raise exception 'INVALID_ACTIVITY_STAFF_REQUEST' using errcode='22023'; end if;
  if not exists(select 1 from app_private.fn_activities where event_id=eid and id=(p_payload->>'activityId')::uuid) then raise exception 'ACTIVITY_STAFF_SCOPE_REQUIRED' using errcode='42501'; end if;
  if not exists(select 1 from auth.users where id=(p_payload->>'userId')::uuid and email_confirmed_at is not null) then raise exception 'VERIFIED_ACTIVITY_STAFF_REQUIRED' using errcode='42501'; end if;
  if (p_payload->>'enabled')::boolean then insert into app_private.fn_activity_staff(event_id,activity_id,user_id) values(eid,(p_payload->>'activityId')::uuid,(p_payload->>'userId')::uuid) on conflict do nothing;
  else delete from app_private.fn_activity_staff where event_id=eid and activity_id=(p_payload->>'activityId')::uuid and user_id=(p_payload->>'userId')::uuid; end if;
  insert into app_private.fn_audit(event_id,actor_id,action,details) values(eid,actor,case when (p_payload->>'enabled')::boolean then 'activity.staff.granted' else 'activity.staff.revoked' end,jsonb_build_object('activityId',(p_payload->>'activityId')::uuid,'userId',(p_payload->>'userId')::uuid,'commandId',p_key));
 elsif p_command='admin.activity.checkin' then
  update app_private.fn_bookings set status='checked_in' where event_id=eid and id=(p_payload->>'bookingId')::uuid and status='booked' and exists(select 1 from app_private.fn_registrations eligible_registration where eligible_registration.event_id=eid and eligible_registration.id=app_private.fn_bookings.registration_id and eligible_registration.status='active' and eligible_registration.payment_status='paid');
  if not found then raise exception 'BOOKING_NOT_ACTIVE' using errcode='22023'; end if;
 elsif p_command='admin.content.save' then
  insert into app_private.fn_content(event_id,content_key,body,published) values(eid,p_payload->>'key',p_payload->'body',coalesce((p_payload->>'published')::boolean,false)) on conflict(event_id,content_key) do update set body=excluded.body,published=excluded.published,version=app_private.fn_content.version+1;
 elsif p_command='push.subscribe' then
  if (p_payload->>'consent')::boolean is distinct from true then raise exception 'EXPLICIT_CONSENT_REQUIRED' using errcode='42501'; end if;
  insert into app_private.fn_push_subscriptions(event_id,actor_id,endpoint_hash,endpoint,p256dh,auth_key)
   values(eid,actor,extensions.digest(coalesce(p_payload->>'endpoint',''),'sha256'),p_payload->>'endpoint',p_payload#>>'{keys,p256dh}',p_payload#>>'{keys,auth}')
   on conflict(event_id,actor_id,endpoint_hash) do update set p256dh=excluded.p256dh,auth_key=excluded.auth_key,consent_at=now(),revoked_at=null;
  result:=jsonb_build_object('subscribed',true,'deliveryMode','no-dispatcher');
 elsif p_command='push.unsubscribe' then
  update app_private.fn_push_subscriptions set revoked_at=now() where event_id=eid and actor_id=actor and (p_payload->>'endpoint' is null or endpoint_hash=extensions.digest(p_payload->>'endpoint','sha256'));
  result:=jsonb_build_object('subscribed',false);
 elsif p_command='notification.read' then
  update app_private.fn_notifications set read_at=now() where event_id=eid and registration_id=rid and id=(p_payload->>'notificationId')::uuid;
 elsif p_command='admin.leases.recover' then
  cnt:=0;
  for x in select dp.id,dp.party_id from app_private.fn_destinations dp where dp.event_id=eid and dp.state='current' and dp.lease_until<now_business order by dp.party_id limit 100 loop
   update app_private.fn_destinations set state='released' where id=x.id;
   update app_private.fn_parties set state='waiting',version=version+1,reason='Jullie reservering is verlopen. Druk op hervatten om een passende actuele bestemming te krijgen.' where id=x.party_id;
   cnt:=cnt+1;
  end loop;
  result:=jsonb_build_object('recovered',cnt);
 elsif p_command='admin.recalculate' then
  select * into target from app_private.fn_parties where event_id=eid and id=(p_payload->>'partyId')::uuid;
  if target.id is null or target.started_at is null or target.state in('finished','merged','archived') then raise exception 'ACTIVE_PARTY_REQUIRED' using errcode='22023'; end if;
  update app_private.fn_destinations set state='released' where party_id=target.id and state='current';
  update app_private.fn_parties set version=version+1 where id=target.id; perform app_private.fn_choose(eid,target.id,coalesce((p_payload->>'returnToDuinpad')::boolean,false));
 elsif p_command='test.walk.fixture' then
  if not f.is_test or f.environment<>'staging' then raise exception 'TEST_SCOPE_REQUIRED' using errcode='42501'; end if;
  insert into app_private.fn_walk_edges(event_id,from_zone_id,to_zone_id,minutes,verified,source)
   select za.event_id,za.id,zb.id,2,true,'synthetic-fixture' from app_private.fn_zones za join app_private.fn_zones zb on zb.event_id=za.event_id and zb.id<>za.id
   where za.event_id=eid and za.synthetic and zb.synthetic and za.run_id=f.run_id and zb.run_id=f.run_id
   on conflict(event_id,from_zone_id,to_zone_id) do nothing;
  result:=jsonb_build_object('synthetic',true,'message','Synthetische looptijden voor routescenario’s; dit zijn geen gecontroleerde wandelpaden op straat.');
 elsif p_command='test.mail.retry' then
  update app_private.fn_mail_sink set attempts=attempts+1 where event_id=eid and id=(p_payload->>'sinkId')::uuid and environment='staging' and delivery_mode='sink';
  if not found then raise exception 'SINK_RECORD_NOT_FOUND' using errcode='22023'; end if;
  result:=jsonb_build_object('mode','sink','externallyDelivered',false);
 elsif p_command='test.clock' then
  if not f.is_test or f.environment<>'staging' then raise exception 'TEST_SCOPE_REQUIRED' using errcode='42501'; end if;
  if (p_payload->>'time')::timestamptz is null then raise exception 'TIME_REQUIRED' using errcode='22023'; end if;
  update app_private.fn_events set test_clock=(p_payload->>'time')::timestamptz,version=version+1 where event_id=eid;
 elsif p_command='test.copy' then
  if not(p_payload->>'slug' like 'frightnight-2027-test-%') or length(p_payload->>'slug')>100 or exists(select 1 from app_private.events where slug=p_payload->>'slug') then raise exception 'NEW_TEST_SLUG_REQUIRED' using errcode='22023'; end if;
  result:=api.frightnight_bootstrap(p_payload->>'slug',actor,'staging','nocteiuvohesvqbowchw:staging:duindorphalloweenstg');
  oid:=(result->>'eventId')::uuid;
  update app_private.fn_events set price_cents=f.price_cents,qr_required=f.qr_required,test_clock=f.test_clock where event_id=oid;
  insert into app_private.fn_quests(event_id,id,title,question,type,answer_hash) select oid,id,title,question,type,answer_hash from app_private.fn_quests where event_id=eid;
  result:=result||jsonb_build_object('copiedConfiguration',true,'copiedPeople',0,'copiedPayments',0,'message','Nieuwe testeditie gemaakt met instellingen en spellen. Seed een eigen synthetisch scenario; bestaande accounts, betalingen en toestemming zijn niet gekopieerd.');
 elsif p_command='test.cleanup' then
  if f.retention_until>now() or p_payload->>'confirmation' is distinct from p_slug or (p_payload->>'runId')::uuid is distinct from f.run_id then raise exception 'RETENTION_SCOPE_CONFLICT' using errcode='42501'; end if;
  perform api.frightnight_command(p_slug,'test.reset',jsonb_build_object('confirmation',p_slug,'runId',f.run_id),gen_random_uuid());
  update app_private.fn_events set closed=true,version=version+1 where event_id=eid;
  result:=jsonb_build_object('archivedExpiredSyntheticData',true,'preservedAuth',true,'preservedFinancialHistory',true);
 elsif p_command='test.reset.preview' then
  result:=jsonb_build_object('eventId',eid,'slug',p_slug,'runId',f.run_id,'syntheticRegistrations',(select count(*) from app_private.fn_registrations where event_id=eid and synthetic and status<>'archived'),'syntheticZones',(select count(*) from app_private.fn_zones where event_id=eid and synthetic and run_id=f.run_id),'preserves',jsonb_build_array('Auth accounts','2026','payments and ledger','audit','real tester registrations','non-synthetic houses'));
 elsif p_command='test.reset' then
  if not f.is_test or f.environment<>'staging' or p_payload->>'confirmation' is distinct from p_slug or (p_payload->>'runId')::uuid is distinct from f.run_id then raise exception 'RESET_SCOPE_CONFLICT' using errcode='42501'; end if;
  update app_private.fn_invites set revoked_at=now() where event_id=eid and revoked_at is null;
  update app_private.fn_registration_invites set revoked_at=now() where event_id=eid and revoked_at is null;
  update app_private.fn_destinations set state='released' where event_id=eid and state='current' and (zone_id in(select id from app_private.fn_zones where event_id=eid and synthetic) or party_id in(select m.party_id from app_private.fn_members m join app_private.fn_registrations rg on rg.id=m.registration_id where rg.event_id=eid and rg.synthetic));
  update app_private.fn_parties set state='archived',version=version+1 where id in(select m.party_id from app_private.fn_members m join app_private.fn_registrations rg on rg.id=m.registration_id where rg.event_id=eid and rg.synthetic) and not exists(select 1 from app_private.fn_members m join app_private.fn_registrations rg on rg.id=m.registration_id where m.party_id=app_private.fn_parties.id and not rg.synthetic);
  update app_private.fn_registrations set status='archived',version=version+1 where event_id=eid and synthetic;
  update app_private.fn_zones set status='closed',review_status='rejected',token_hash=extensions.gen_random_bytes(32),token_version=token_version+1,version=version+1 where event_id=eid and synthetic;
  update app_private.fn_events set run_id=gen_random_uuid(),seed_version=0,start_token_hash=null,version=version+1 where event_id=eid; result:=jsonb_build_object('archived',true);
 elsif p_command='test.seed' then
  result:=app_private.fn_seed(eid,actor);
 elsif p_command='qr.issue' then
  if p_payload->>'zoneId' is null then
   if not app_private.has_capability(eid,'event_admin',actor) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   tok:=encode(extensions.hmac(eid::text||':start:'||f.run_id::text||':'||f.seed_version,encode(f.qr_secret,'hex'),'sha256'),'hex');
   update app_private.fn_events set start_token_hash=extensions.digest(tok,'sha256') where event_id=eid;
   result:=jsonb_build_object('token',tok,'zone',jsonb_build_object('id',null,'name','Oogstdorp · Start Duinpad','type','start','address','Duinpad'));
  else
   select * into z from app_private.fn_zones where event_id=eid and id=(p_payload->>'zoneId')::uuid;
   if z.id is null or not(coalesce(z.owner_id=actor,false) or app_private.fn_can(eid,'portals_manage',actor)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   if z.review_status<>'approved' then raise exception 'APPROVAL_REQUIRED' using errcode='22023'; end if;
   tok:=encode(extensions.hmac(z.id::text||':'||z.token_version,encode(f.qr_secret,'hex'),'sha256'),'hex');
   update app_private.fn_zones set token_hash=extensions.digest(tok,'sha256') where id=z.id;
   result:=jsonb_build_object('token',tok,'zone',app_private.fn_zone_json(z.id,true));
  end if;
 elsif p_command='admin.walk.verify' then
  if (p_payload->>'verified')::boolean is distinct from true or length(coalesce(p_payload->>'reason',''))<10 then raise exception 'WALK_VERIFICATION_REQUIRED' using errcode='22023'; end if;
  if not app_private.fn_walk_geometry_valid(p_payload->'geometry') then raise exception 'INVALID_DUINDORP_WALK_GEOMETRY' using errcode='22023'; end if;
  insert into app_private.fn_walk_edges(event_id,from_zone_id,to_zone_id,minutes,geometry,verified,source) values(eid,(p_payload->>'fromZoneId')::uuid,(p_payload->>'toZoneId')::uuid,(p_payload->>'minutes')::integer,nullif(p_payload->'geometry','null'::jsonb),true,'organisation-verified') on conflict(event_id,from_zone_id,to_zone_id) do update set minutes=excluded.minutes,geometry=excluded.geometry,verified=true,source='organisation-verified';
 else raise exception 'UNKNOWN_COMMAND' using errcode='22023'; end if;
 insert into app_private.fn_audit(event_id,actor_id,action,details) values(eid,actor,p_command,jsonb_build_object('commandId',p_key,'engineVersion','deterministic-v1'));
 response:=jsonb_build_object('ok',true,'result',result,'snapshot',api.frightnight_snapshot(p_slug));
 -- Secret QR/invite values exist only in a private actor-bound command receipt;
 -- they are never included in snapshots, audit, public content or telemetry.
 -- Persist only the immutable result and registration binding needed for replay
 -- authorization. Administrative rosters/contact fields are freshly projected
 -- for each response, never copied into this idempotency ledger.
 insert into app_private.fn_receipts(event_id,actor_id,command_key,request_hash,result) values(eid,actor,p_key,request_digest,jsonb_build_object('result',result,'snapshot',jsonb_build_object('registration',jsonb_build_object('id',response#>'{snapshot,registration,id}'))));
 return response;
end $$;
create table app_private.fn_refunds (
 event_id uuid not null, order_id uuid not null, command_key uuid not null, actor_id uuid not null references auth.users(id),
 reason text not null check(length(reason) between 5 and 500), provider_ref text, status text not null default 'requested' check(status in('requested','queued','pending','processing','refunded','failed','canceled')),
 created_at timestamptz not null default now(), primary key(event_id,command_key), foreign key(event_id,order_id) references app_private.fn_orders(event_id,id)
);
create unique index fn_refunds_active_order on app_private.fn_refunds(event_id,order_id) where status in('requested','queued','pending','processing','refunded');
create function app_private.fn_order_json(p_id uuid) returns jsonb language sql stable set search_path='' as $$ select jsonb_build_object('order_id',id,'event_id',event_id,'registration_id',registration_id,'amount_cents',amount_cents,'currency',currency,'status',status,'provider_ref',provider_ref,'checkout_url',checkout_url) from app_private.fn_orders where id=p_id $$;
create function api.frightnight_payment_create(p_slug text,p_actor uuid,p_key uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; rid uuid; r app_private.fn_registrations; oid uuid;
begin
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test and not f.closed for update of f;
 if eid is null or p_actor is null or p_key is null then raise exception 'TEST_SCOPE_REQUIRED' using errcode='42501'; end if;
 rid:=app_private.fn_registration(eid,p_actor); select * into r from app_private.fn_registrations where id=rid;
 if r.id is null or r.status in('cancelled','archived') then raise exception 'REGISTRATION_REQUIRED' using errcode='42501'; end if;
 select id into oid from app_private.fn_orders where event_id=eid and registration_id=rid and (idempotency_key=p_key or status in('open','paid')) order by created_at desc limit 1;
 if coalesce(app_private.fn_slot_available(eid,r.start_slot,rid),-1)<r.adults+r.children then raise exception 'START_SLOT_FULL' using errcode='22023'; end if;
 if oid is null then insert into app_private.fn_orders(event_id,registration_id,amount_cents,idempotency_key) values(eid,rid,r.amount_cents,p_key) returning id into oid; update app_private.fn_registrations set payment_status='open',version=version+1 where id=rid; else update app_private.fn_orders set hold_until=now()+interval '15 minutes' where id=oid and status='open'; end if;
 return app_private.fn_order_json(oid);
end $$;
create function api.frightnight_payment_bind(p_slug text,p_order_id uuid,p_provider_ref text,p_checkout_url text) returns jsonb language plpgsql security definer set search_path='' as $$
declare o app_private.fn_orders;
begin
 select ord.* into o from app_private.fn_orders ord join app_private.events e on e.id=ord.event_id join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test and ord.id=p_order_id for update of ord;
 if o.id is null or p_provider_ref is null or not(p_provider_ref~'^(tr_[A-Za-z0-9]+|ct_[a-f0-9-]{36})$') then raise exception 'INVALID_PAYMENT_BINDING' using errcode='22023'; end if;
 if o.provider_ref is not null and o.provider_ref<>p_provider_ref then raise exception 'PAYMENT_ALREADY_BOUND' using errcode='40001'; end if;
 if p_checkout_url is not null and not(p_checkout_url ~ '^https://([a-zA-Z0-9-]+\.)*mollie\.com/' or (p_provider_ref like 'ct_%' and p_checkout_url like 'https://staging-halloween.duindorpdoet.nl/%')) then raise exception 'INVALID_CHECKOUT_URL' using errcode='22023'; end if;
 update app_private.fn_orders set provider_ref=p_provider_ref,checkout_url=coalesce(p_checkout_url,checkout_url),provider=case when p_provider_ref like 'ct_%' then 'contract' else 'mollie' end where id=o.id; return app_private.fn_order_json(o.id);
end $$;
create function api.frightnight_payment_scope(p_provider_ref text) returns jsonb language sql stable security definer set search_path='' as $$ select jsonb_build_object('slug',e.slug) from app_private.fn_orders o join app_private.events e on e.id=o.event_id join app_private.fn_events f on f.event_id=e.id where f.environment='staging' and f.is_test and (e.slug='frightnight-2027-test' or e.slug like 'frightnight-2027-test-%') and o.provider_ref=p_provider_ref $$;
create function api.frightnight_payment_lookup(p_slug text,p_provider_ref text) returns jsonb language sql stable security definer set search_path='' as $$ select app_private.fn_order_json(o.id) from app_private.fn_orders o join app_private.events e on e.id=o.event_id join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test and o.provider_ref=p_provider_ref $$;
create function api.frightnight_payment_for_actor(p_slug text,p_actor uuid) returns jsonb language sql stable security definer set search_path='' as $$ select app_private.fn_order_json(o.id) from app_private.fn_orders o join app_private.events e on e.id=o.event_id join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test and o.registration_id=app_private.fn_registration(e.id,p_actor) order by o.created_at desc limit 1 $$;
create function api.frightnight_payment_confirm(p_slug text,p_provider_ref text,p_status text,p_amount_cents integer,p_currency text,p_provider_event text,p_metadata jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare o app_private.fn_orders; v_status text; is_duplicate boolean; quote_matches boolean; quote_cancelled boolean; eid uuid;
begin
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test;
 if eid is null then raise exception 'TEST_SCOPE_REQUIRED' using errcode='42501'; end if;
 perform 1 from app_private.fn_events where event_id=eid for update;
 select ord.* into o from app_private.fn_orders ord join app_private.events e on e.id=ord.event_id join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test and ord.provider_ref=p_provider_ref for update of ord;
 if o.id is null or p_metadata->>'order_id' is distinct from o.id::text or p_metadata->>'event_id' is distinct from o.event_id::text or (p_metadata->>'testmode')::boolean is distinct from true or p_metadata->>'environment' is distinct from 'staging' or p_amount_cents<>o.amount_cents or p_currency<>o.currency or p_provider_event is null then raise exception 'PROVIDER_CONFIRMATION_MISMATCH' using errcode='22023'; end if;
 v_status:=case when p_status in('pending','authorized') then 'open' when p_status='canceled' then 'cancelled' else p_status end;
 if v_status not in('open','paid','failed','cancelled','expired','refunded') then raise exception 'INVALID_PROVIDER_STATE' using errcode='22023'; end if;
 insert into app_private.fn_payment_events(event_id,order_id,provider_event,status) values(o.event_id,o.id,p_provider_event,v_status) on conflict do nothing;
 is_duplicate:=not found;
 if is_duplicate then return app_private.fn_order_json(o.id); end if;
 if o.status='refunded' or (o.status='paid' and v_status<>'refunded') then return app_private.fn_order_json(o.id); end if;
 if v_status='refunded' and o.status<>'paid' then raise exception 'PAID_ORDER_REQUIRED' using errcode='22023'; end if;
 update app_private.fn_orders set status=v_status where id=o.id;
 select r.amount_cents=o.amount_cents,(r.status in('cancelled','archived') or exists(select 1 from app_private.fn_orders prior where prior.event_id=eid and prior.registration_id=r.id and prior.status='refunded')) into quote_matches,quote_cancelled from app_private.fn_registrations r where r.event_id=eid and r.id=o.registration_id;
 -- An older failed attempt cannot revoke a later confirmed payment. Financial
 -- receipt truth is retained even if an inconsistent quote requires assistance.
 if v_status in('paid','refunded') or not exists(select 1 from app_private.fn_orders where event_id=eid and registration_id=o.registration_id and id<>o.id and status='paid') then
  update app_private.fn_registrations set payment_status=v_status,status=case when v_status='paid' and quote_cancelled then case when app_private.fn_registrations.status='archived' then 'archived' else 'cancelled' end when v_status='paid' and quote_matches and coalesce(app_private.fn_slot_available(o.event_id,app_private.fn_registrations.start_slot,o.registration_id),-1)>=adults+children then 'active' when v_status='paid' then 'draft' when v_status='refunded' then 'cancelled' else app_private.fn_registrations.status end,version=version+1 where event_id=eid and id=o.registration_id;
 end if;
 if v_status='paid' and (not quote_matches or quote_cancelled) then
  update app_private.fn_bookings set status='cancelled' where event_id=eid and registration_id=o.registration_id and status='booked';
  update app_private.fn_destinations set state='released' where event_id=eid and state='current' and party_id in(select party_id from app_private.fn_members where event_id=eid and registration_id=o.registration_id);
  update app_private.fn_parties set state='paused',version=version+1,reason=case when quote_cancelled then 'Een betaling is ontvangen na annulering. Nieuwe tochtrechten blijven geblokkeerd; stem af met het hulppunt.' else 'Betaalbedrag en inschrijving sluiten niet aan. Stem eerst af met het hulppunt.' end where event_id=eid and id in(select party_id from app_private.fn_members where event_id=eid and registration_id=o.registration_id) and state in('ready','walking','waiting','paused');
 end if;
 if v_status='paid' then
  insert into app_private.fn_ledger(event_id,order_id,kind,amount_cents) values(o.event_id,o.id,'receipt',o.amount_cents) on conflict do nothing;
  insert into app_private.fn_notifications(event_id,registration_id,title,message,dedupe_key) values(o.event_id,o.registration_id,case when quote_cancelled then 'Betaling ontvangen na annulering' when not quote_matches then 'Betaling ontvangen; bedrag afstemmen' when (select status from app_private.fn_registrations where id=o.registration_id)='active' then 'Je Nachtpas staat klaar' else 'Betaling ontvangen; startmoment afstemmen' end,case when quote_cancelled then 'Een oude betaalpoging is na annulering alsnog betaald. Je inschrijving blijft geannuleerd; neem contact op met het hulppunt voor controle of testterugbetaling.' when not quote_matches then 'Het ontvangen bedrag past niet bij de vastgelegde inschrijving. Nieuwe tochtrechten blijven geblokkeerd; neem contact op met het hulppunt voor controle of testterugbetaling.' when (select status from app_private.fn_registrations where id=o.registration_id)='active' then 'Je testbetaling is bevestigd. Bekijk je tocht en verwachte startmoment.' else 'De tijdelijke startreservering was verlopen en dit blok is vol. Neem contact op met het hulppunt voor omboeken of testterugbetaling.' end,'paid:'||o.id) on conflict do nothing;
  insert into app_private.fn_mail_sink(event_id,registration_id,dedupe_key,template,payload) values(o.event_id,o.registration_id,'paid:'||o.id,'frightnight-payment-confirmed',jsonb_build_object('orderId',o.id,'amountCents',o.amount_cents,'brandVersion',7,'fulfillment',case when quote_cancelled then 'cancelled' when not quote_matches then 'quote_mismatch' when (select status from app_private.fn_registrations where id=o.registration_id)='active' then 'active' else 'start_required' end)) on conflict do nothing;
 elsif v_status='refunded' then
  update app_private.fn_bookings set status='cancelled' where event_id=eid and registration_id=o.registration_id and status='booked';
  insert into app_private.fn_ledger(event_id,order_id,kind,amount_cents) values(o.event_id,o.id,'refund',-o.amount_cents) on conflict do nothing;
  update app_private.fn_refunds set status='refunded' where event_id=o.event_id and order_id=o.id and status in('requested','queued','pending','processing');
  -- Refunds stop route rights. Release the whole shared reservation and pause the
  -- party for explicit regrouping; never leave a paid-status mismatch en route.
  update app_private.fn_destinations set state='released' where state='current' and party_id in(select party_id from app_private.fn_members where registration_id=o.registration_id);
  update app_private.fn_parties set state='paused',version=version+1,reason='Een inschrijving is terugbetaald. Neem contact op met het hulppunt om opnieuw af te stemmen.' where id in(select party_id from app_private.fn_members where registration_id=o.registration_id) and state in('ready','walking','waiting','paused');
 end if;
 insert into app_private.fn_audit(event_id,action,details) values(o.event_id,'payment.provider-confirmed',jsonb_build_object('orderId',o.id,'status',v_status,'provider',o.provider)); return app_private.fn_order_json(o.id);
end $$;
create function api.frightnight_payment_test_order(p_slug text,p_actor uuid,p_registration uuid,p_key uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; r app_private.fn_registrations; oid uuid;
begin
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.is_test and f.environment='staging' for update of f;
 if eid is null or not app_private.has_capability(eid,'event_admin',p_actor) then raise exception 'TEST_ADMIN_REQUIRED' using errcode='42501'; end if;
 select * into r from app_private.fn_registrations where event_id=eid and id=p_registration and status<>'archived';
 if r.id is null then raise exception 'REGISTRATION_REQUIRED' using errcode='22023'; end if;
 select id into oid from app_private.fn_orders where event_id=eid and registration_id=r.id and (idempotency_key=p_key or status in('open','paid')) order by created_at desc limit 1;
 if oid is null then insert into app_private.fn_orders(event_id,registration_id,amount_cents,idempotency_key,provider) values(eid,r.id,r.amount_cents,p_key,'contract') returning id into oid; end if; return app_private.fn_order_json(oid);
end $$;
create function api.frightnight_payment_for_refund(p_slug text,p_actor uuid,p_registration uuid,p_key uuid,p_reason text) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; oid uuid; old app_private.fn_refunds;
begin
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.is_test and f.environment='staging' for update of f;
 if eid is null or not app_private.fn_can(eid,'payments_manage',p_actor) then raise exception 'FINANCE_REQUIRED' using errcode='42501'; end if;
 select * into old from app_private.fn_refunds where event_id=eid and command_key=p_key;
 if found then if old.actor_id<>p_actor or old.reason<>p_reason or not exists(select 1 from app_private.fn_orders where id=old.order_id and event_id=eid and registration_id=p_registration) then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='40001'; end if; return app_private.fn_order_json(old.order_id); end if;
 select id into oid from app_private.fn_orders where event_id=eid and registration_id=p_registration and status in('paid','refunded') order by (status='paid') desc,created_at desc limit 1;
 if oid is null then raise exception 'PAID_ORDER_REQUIRED' using errcode='22023'; end if;
 if exists(select 1 from app_private.fn_orders where event_id=eid and id=oid and status='refunded') then return app_private.fn_order_json(oid); end if;
 if exists(select 1 from app_private.fn_refunds where event_id=eid and order_id=oid and status in('requested','queued','pending','processing','refunded')) then raise exception 'REFUND_ALREADY_REQUESTED' using errcode='40001'; end if;
 insert into app_private.fn_refunds(event_id,order_id,command_key,actor_id,reason) values(eid,oid,p_key,p_actor,p_reason); return app_private.fn_order_json(oid);
end $$;
create function api.frightnight_payment_refund_record(p_slug text,p_actor uuid,p_order_id uuid,p_provider_ref text,p_status text,p_key uuid,p_reason text) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; o app_private.fn_orders; ref app_private.fn_refunds;
begin
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.is_test and f.environment='staging' for update of f;
 if eid is null or not app_private.fn_can(eid,'payments_manage',p_actor) then raise exception 'FINANCE_REQUIRED' using errcode='42501'; end if;
 select * into ref from app_private.fn_refunds where event_id=eid and command_key=p_key and order_id=p_order_id and actor_id=p_actor and reason=p_reason for update;
 if ref.order_id is null then raise exception 'REFUND_REQUEST_REQUIRED' using errcode='42501'; end if;
 if p_status is null or p_status not in('queued','pending','processing','refunded','failed','canceled') then raise exception 'INVALID_REFUND_STATE' using errcode='22023'; end if;
 if ref.status='refunded' then return app_private.fn_order_json(p_order_id); end if;
 if ref.provider_ref is not null and ref.provider_ref<>p_provider_ref then raise exception 'REFUND_PROVIDER_CONFLICT' using errcode='40001'; end if;
 update app_private.fn_refunds set provider_ref=p_provider_ref,status=p_status where event_id=eid and command_key=p_key;
 select * into o from app_private.fn_orders where event_id=eid and id=p_order_id;
 if p_status='refunded' then perform api.frightnight_payment_confirm(p_slug,o.provider_ref,'refunded',o.amount_cents,o.currency,'refund:'||p_provider_ref,jsonb_build_object('order_id',o.id,'event_id',eid,'testmode',true,'environment','staging')); end if;
 return app_private.fn_order_json(p_order_id);
end $$;
create function api.frightnight_walk(p_slug text,p_destination_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare eid uuid; rid uuid; d app_private.fn_destinations; previous uuid; geo jsonb; edge_source text;
begin
 if auth.uid() is null then raise exception 'LOGIN_REQUIRED' using errcode='42501'; end if;
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test;
 rid:=app_private.fn_registration(eid,auth.uid());
 select dest.* into d from app_private.fn_destinations dest join app_private.fn_members m on m.party_id=dest.party_id and m.registration_id=rid where dest.event_id=eid and dest.id=p_destination_id and dest.state='current';
 if d.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select zone_id into previous from app_private.fn_destinations where party_id=d.party_id and sequence<d.sequence order by sequence desc limit 1;
 if previous is null then select id into previous from app_private.fn_zones where event_id=eid and type='finale' and review_status='approved'; end if;
 select geometry,source into geo,edge_source from app_private.fn_walk_edges where event_id=eid and from_zone_id=previous and to_zone_id=d.zone_id and verified;
 if edge_source is null then edge_source:=case when exists(select 1 from app_private.fn_walk_edges where event_id=eid and source='synthetic-fixture') then 'synthetic-fixture' else 'unavailable' end; end if;
 return jsonb_build_object('from',(select jsonb_build_object('latitude',latitude,'longitude',longitude) from app_private.fn_zones where id=previous),'to',(select jsonb_build_object('latitude',latitude,'longitude',longitude) from app_private.fn_zones where id=d.zone_id),'available',geo is not null and edge_source='organisation-verified','geometry',case when edge_source='organisation-verified' then geo else null end,'minutes',d.walk_minutes,'source',edge_source,'message',case when edge_source='synthetic-fixture' then 'Deze synthetische testgraaf bevat geen gecontroleerd straatpad.' when geo is null then 'Er is nog geen gecontroleerd wandelpad beschikbaar. Vraag de ontvangst op het Duinpad om de papieren loopinstructie.' else 'Volg het gecontroleerde wandelpad. Let op verkeer en aanwijzingen ter plaatse.' end);
end $$;
create function api.frightnight_bootstrap(p_slug text,p_actor uuid,p_environment text,p_confirmation text) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid;
begin
 if p_environment<>'staging' or not(p_slug='frightnight-2027-test' or p_slug like 'frightnight-2027-test-%') or p_confirmation<>'nocteiuvohesvqbowchw:staging:duindorphalloweenstg' then raise exception 'VERIFIED_STAGING_BINDING_REQUIRED' using errcode='42501'; end if;
 if not exists(select 1 from app_private.event_capabilities where user_id=p_actor and capability='event_admin' and revoked_at is null) then raise exception 'EXISTING_ADMIN_REQUIRED' using errcode='42501'; end if;
 insert into app_private.events(slug,title,local_date,timezone,phase,price_cents,settings) values(p_slug,'Duindorp FrightNight 2027 · TEST',date '2027-10-30','Europe/Amsterdam','draft',350,jsonb_build_object('engine','frightnight-v1','test',true,'legacyRegistrationDisabled',true)) on conflict(slug) do nothing;
 select id into eid from app_private.events where slug=p_slug;
 if exists(select 1 from app_private.registrations where event_id=eid) or exists(select 1 from app_private.walking_groups where event_id=eid) then raise exception 'LEGACY_EVENT_BINDING_FORBIDDEN' using errcode='42501'; end if;
 insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('frightnight-zone-photos','frightnight-zone-photos',false,5242880,array['image/webp']) on conflict(id) do nothing;
 if exists(select 1 from storage.buckets where id='frightnight-zone-photos' and (public or file_size_limit is distinct from 5242880 or allowed_mime_types is distinct from array['image/webp']::text[])) then raise exception 'UNSAFE_EXISTING_PHOTO_BUCKET' using errcode='42501'; end if;
 insert into app_private.fn_events(event_id,environment) values(eid,'staging') on conflict do nothing;
 insert into app_private.fn_start_slots(event_id,starts_at,route_type)
 select eid,(date '2027-10-30'+s.time::time) at time zone 'Europe/Amsterdam',case when s.time::time<time '18:30' then 'lantern' else 'roots' end
 from generate_series(timestamp '2027-10-30 17:00',timestamp '2027-10-30 20:45',interval '15 minutes')s(time) on conflict do nothing;
 insert into app_private.event_capabilities(event_id,user_id,capability,granted_by) values(eid,p_actor,'event_admin',p_actor) on conflict do nothing;
 if not exists(select 1 from app_private.fn_audit where event_id=eid and action='event.bootstrap') then insert into app_private.fn_audit(event_id,actor_id,action,details) values(eid,p_actor,'event.bootstrap',jsonb_build_object('environment','staging','bindingConfirmed',true)); end if; return jsonb_build_object('eventId',eid,'slug',p_slug);
end $$;
create function api.frightnight_initialize(p_slug text,p_actor uuid,p_confirmation text) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid; f app_private.fn_events; seeded boolean:=false;
begin
 if p_slug<>'frightnight-2027-test' or p_confirmation<>'nocteiuvohesvqbowchw:staging:duindorphalloweenstg' then raise exception 'VERIFIED_STAGING_BINDING_REQUIRED' using errcode='42501'; end if;
 select e.id into eid from app_private.events e join app_private.fn_events fe on fe.event_id=e.id where e.slug=p_slug and fe.environment='staging' and fe.is_test;
 select * into f from app_private.fn_events where event_id=eid for update;
 if eid is null or not app_private.has_capability(eid,'event_admin',p_actor) then raise exception 'EXPLICIT_EVENT_ADMIN_REQUIRED' using errcode='42501'; end if;
 if f.seed_version=0 then perform app_private.fn_seed(eid,p_actor); seeded:=true; end if;
 insert into app_private.fn_walk_edges(event_id,from_zone_id,to_zone_id,minutes,verified,source)
 select za.event_id,za.id,zb.id,2,true,'synthetic-fixture' from app_private.fn_zones za join app_private.fn_zones zb on zb.event_id=za.event_id and zb.id<>za.id
 where za.event_id=eid and za.synthetic and zb.synthetic and za.run_id=f.run_id and zb.run_id=f.run_id on conflict do nothing;
 if not exists(select 1 from app_private.fn_audit where event_id=eid and action='automation.initialize' and details->>'runId'=f.run_id::text) then
  insert into app_private.fn_audit(event_id,actor_id,action,details) values(eid,p_actor,'automation.initialize',jsonb_build_object('delegation','service-role:verified-staging-release','runId',f.run_id,'syntheticOnly',true,'jwtImpersonation',false));
 end if;
 return jsonb_build_object('eventId',eid,'slug',p_slug,'seeded',seeded,'seedVersion',(select seed_version from app_private.fn_events where event_id=eid),'mailMode','sink','externalDelivery',false,'syntheticWalkFixture',true);
end $$;
create function api.frightnight_public_content(p_slug text) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('key',c.content_key,'body',c.body,'version',c.version) order by c.content_key),'[]') from app_private.fn_content c join app_private.events e on e.id=c.event_id join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test and c.published
$$;
create function api.frightnight_admin_list(p_slug text,p_resource text,p_cursor integer default 0,p_limit integer default 50,p_search text default '',p_filters jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare eid uuid; actor uuid:=auth.uid(); items jsonb; total bigint; lim integer:=least(greatest(coalesce(p_limit,50),1),100); offst integer:=greatest(coalesce(p_cursor,0),0); cap text; search text:=lower(trim(coalesce(p_search,''))); filters jsonb:=coalesce(p_filters,'{}'); allowed text[]; st text; rt text; ps text;
begin
 if actor is null then raise exception 'LOGIN_REQUIRED' using errcode='42501'; end if;
 select e.id into eid from app_private.events e join app_private.fn_events f on f.event_id=e.id where e.slug=p_slug and f.environment='staging' and f.is_test;
 cap:=case when p_resource='zones' then 'portals_manage' when p_resource in('registrations','parties') then 'registration_manage' when p_resource in('payments','sink') then 'payments_manage' when p_resource='incidents' then 'live_support' when p_resource in('content','announcements') then 'content_manage' else 'event_admin' end;
 if eid is null or not(app_private.fn_can(eid,cap,actor) or (p_resource='bookings' and exists(select 1 from app_private.fn_activity_staff where event_id=eid and user_id=actor))) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if offst>100000 or length(search)>120 or jsonb_typeof(filters)<>'object' or octet_length(filters::text)>2048 then raise exception 'INVALID_ADMIN_QUERY' using errcode='22023'; end if;
 allowed:=case when p_resource='registrations' then array['status','routeType','paymentStatus'] when p_resource in('payments','incidents','bookings','parties','sink') then array['status','routeType'] when p_resource in('zones','content') then array['status'] when p_resource in('audit','announcements') then array[]::text[] else null end;
 if allowed is null then raise exception 'UNKNOWN_RESOURCE' using errcode='22023'; end if;
 if exists(select 1 from jsonb_each(filters) x where not x.key=any(allowed) or jsonb_typeof(x.value)<>'string' or length(x.value#>>'{}')>100) then raise exception 'INVALID_ADMIN_FILTER' using errcode='22023'; end if;
 st:=nullif(filters->>'status',''); rt:=nullif(filters->>'routeType',''); ps:=nullif(filters->>'paymentStatus','');
 if rt is not null and rt not in('lantern','roots') then raise exception 'INVALID_ADMIN_FILTER' using errcode='22023'; end if;
 if ps is not null and ps not in('unpaid','open','paid','failed','cancelled','expired','refunded') then raise exception 'INVALID_ADMIN_FILTER' using errcode='22023'; end if;
 if st is not null and not(st=any(case p_resource when 'registrations' then array['draft','active','cancelled','archived'] when 'zones' then array['open','busy','paused','closed'] when 'payments' then array['open','paid','failed','cancelled','expired','refunded'] when 'incidents' then array['open','resolved'] when 'bookings' then array['booked','cancelled','checked_in'] when 'parties' then array['ready','walking','waiting','paused','finished','merged','archived'] when 'sink' then array['sink'] when 'content' then array['draft','published'] else array[]::text[] end)) then raise exception 'INVALID_ADMIN_FILTER' using errcode='22023'; end if;
 if p_resource='zones' then
  with matched as materialized(select z.id::text sort_id,z.opens_at sort_time,z.id from app_private.fn_zones z where z.event_id=eid and (st is null or app_private.fn_zone_status(z.id)=st) and (search='' or position(search in lower(z.name||' '||z.address))>0))
  select (select count(*) from matched),coalesce((select jsonb_agg(app_private.fn_zone_json(t.id,true) order by t.sort_time desc,t.sort_id desc) from(select * from matched order by sort_time desc,sort_id desc limit lim offset offst)t),'[]'::jsonb) into total,items;
 elsif p_resource='registrations' then
  with matched as materialized(select r.id::text sort_id,r.created_at sort_time,r.id from app_private.fn_registrations r where r.event_id=eid and (st is not null or r.status<>'archived') and (st is null or r.status=st) and (rt is null or r.route_type=rt) and (ps is null or r.payment_status=ps) and (search='' or position(search in lower(r.label||' '||r.id::text))>0))
  select (select count(*) from matched),coalesce((select jsonb_agg(app_private.fn_registration_json(t.id) order by t.sort_time desc,t.sort_id desc) from(select * from matched order by sort_time desc,sort_id desc limit lim offset offst)t),'[]'::jsonb) into total,items;
 elsif p_resource='payments' then
  with matched as materialized(select o.id::text sort_id,o.created_at sort_time,o.id,r.label,r.route_type from app_private.fn_orders o join app_private.fn_registrations r on r.event_id=o.event_id and r.id=o.registration_id where o.event_id=eid and (st is null or o.status=st) and (rt is null or r.route_type=rt) and (search='' or position(search in lower(r.label||' '||o.id::text||' '||coalesce(o.provider_ref,'')))>0))
  select (select count(*) from matched),coalesce((select jsonb_agg(app_private.fn_order_json(t.id)||jsonb_build_object('registrationLabel',t.label,'routeType',t.route_type) order by t.sort_time desc,t.sort_id desc) from(select * from matched order by sort_time desc,sort_id desc limit lim offset offst)t),'[]'::jsonb) into total,items;
 elsif p_resource='audit' then
  with matched as materialized(select lpad(a.id::text,20,'0') sort_id,a.created_at sort_time,a.id,a.action,a.details,a.created_at from app_private.fn_audit a where a.event_id=eid and (search='' or position(search in lower(a.action))>0))
  select (select count(*) from matched),coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'action',t.action,'details',t.details,'createdAt',t.created_at) order by t.sort_time desc,t.sort_id desc) from(select * from matched order by sort_time desc,sort_id desc limit lim offset offst)t),'[]'::jsonb) into total,items;
 elsif p_resource='incidents' then
  with matched as materialized(select i.id::text sort_id,i.created_at sort_time,i.id,i.category,i.text,i.status,i.response_text,i.created_at from app_private.fn_incidents i left join app_private.fn_registrations r on r.id=app_private.fn_registration(eid,i.actor_id) and r.event_id=i.event_id where i.event_id=eid and (st is null or i.status=st) and (rt is null or r.route_type=rt) and (search='' or position(search in lower(i.category||' '||i.text||' '||coalesce(i.response_text,'')))>0))
  select (select count(*) from matched),coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'category',t.category,'text',t.text,'status',t.status,'response',t.response_text,'createdAt',t.created_at) order by t.sort_time desc,t.sort_id desc) from(select * from matched order by sort_time desc,sort_id desc limit lim offset offst)t),'[]'::jsonb) into total,items;
 elsif p_resource='bookings' then
  with matched as materialized(select b.id::text sort_id,a.starts_at sort_time,b.id,b.activity_id,b.registration_id,b.seats,b.status,r.label,r.route_type,a.name from app_private.fn_bookings b join app_private.fn_registrations r on r.event_id=b.event_id and r.id=b.registration_id join app_private.fn_activities a on a.event_id=b.event_id and a.id=b.activity_id where b.event_id=eid and (app_private.has_capability(eid,'event_admin',actor) or exists(select 1 from app_private.fn_activity_staff fs where fs.event_id=eid and fs.activity_id=b.activity_id and fs.user_id=actor)) and (st is null or b.status=st) and (rt is null or r.route_type=rt) and (search='' or position(search in lower(r.label||' '||a.name))>0))
  select (select count(*) from matched),coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'activityId',t.activity_id,'registrationId',t.registration_id,'registrationLabel',t.label,'routeType',t.route_type,'activityName',t.name,'seats',t.seats,'status',t.status) order by t.sort_time desc,t.sort_id desc) from(select * from matched order by sort_time desc,sort_id desc limit lim offset offst)t),'[]'::jsonb) into total,items;
 elsif p_resource='parties' then
  with matched as materialized(select p.id::text sort_id,coalesce(p.started_at,'epoch'::timestamptz) sort_time,p.id,p.state,p.version from app_private.fn_parties p where p.event_id=eid and (st is null or p.state=st) and (rt is null or exists(select 1 from app_private.fn_members m join app_private.fn_registrations r on r.event_id=m.event_id and r.id=m.registration_id where m.party_id=p.id and r.route_type=rt)) and (search='' or exists(select 1 from app_private.fn_members m join app_private.fn_registrations r on r.event_id=m.event_id and r.id=m.registration_id where m.party_id=p.id and position(search in lower(r.label))>0)))
  select (select count(*) from matched),coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'state',t.state,'version',t.version,'preferences',app_private.fn_party_preferences(t.id)) order by t.sort_time desc,t.sort_id desc) from(select * from matched order by sort_time desc,sort_id desc limit lim offset offst)t),'[]'::jsonb) into total,items;
 elsif p_resource='sink' then
  with matched as materialized(select m.id::text sort_id,m.created_at sort_time,m.id,m.template,m.payload,m.delivery_mode,m.attempts,m.created_at from app_private.fn_mail_sink m left join app_private.fn_registrations r on r.event_id=m.event_id and r.id=m.registration_id where m.event_id=eid and (st is null or m.delivery_mode=st) and (rt is null or r.route_type=rt) and (search='' or position(search in lower(m.id::text||' '||m.template||' '||coalesce(r.label,'')))>0))
  select (select count(*) from matched),coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'template',t.template,'payload',t.payload,'mode',t.delivery_mode,'attempts',t.attempts,'createdAt',t.created_at) order by t.sort_time desc,t.sort_id desc) from(select * from matched order by sort_time desc,sort_id desc limit lim offset offst)t),'[]'::jsonb) into total,items;
 elsif p_resource='content' then
  with matched as materialized(select c.content_key sort_id,'epoch'::timestamptz sort_time,c.content_key,c.body,c.published,c.version from app_private.fn_content c where c.event_id=eid and (st is null or c.published=(st='published')) and (search='' or position(search in lower(c.content_key||' '||c.body::text))>0))
  select (select count(*) from matched),coalesce((select jsonb_agg(jsonb_build_object('key',t.content_key,'body',t.body,'published',t.published,'version',t.version) order by t.sort_time desc,t.sort_id desc) from(select * from matched order by sort_time desc,sort_id desc limit lim offset offst)t),'[]'::jsonb) into total,items;
 elsif p_resource='announcements' then
  with matched as materialized(select a.id::text sort_id,a.created_at sort_time,a.id,a.text,a.audience,a.target_id,a.version,a.created_at,a.updated_at from app_private.fn_announcements a where a.event_id=eid and (search='' or position(search in lower(a.text))>0))
  select (select count(*) from matched),coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'text',t.text,'audience',t.audience,'targetId',t.target_id,'version',t.version,'createdAt',t.created_at,'updatedAt',t.updated_at) order by t.sort_time desc,t.sort_id desc) from(select * from matched order by sort_time desc,sort_id desc limit lim offset offst)t),'[]'::jsonb) into total,items;
 end if;
 return jsonb_build_object('items',items,'total',total,'nextCursor',case when offst+lim<total then offst+lim else null end,'limit',lim,'search',trim(coalesce(p_search,'')),'filters',filters);
end $$;

-- Photographs remain private, with ownership checked again by Storage RLS.
-- Bucket creation is part of post-preservation, service-only bootstrap.
create function app_private.fn_photo_access(p_name text) returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from app_private.fn_zones z join app_private.fn_events f on f.event_id=z.event_id
 where z.event_id::text=split_part(p_name,'/',1) and z.id::text=split_part(p_name,'/',2) and auth.uid()::text=split_part(p_name,'/',3) and f.environment='staging' and f.is_test and (z.owner_id=auth.uid() or app_private.fn_can(z.event_id,'portals_manage',auth.uid())))
$$;
create policy frightnight_photo_insert on storage.objects for insert to authenticated with check(bucket_id='frightnight-zone-photos' and app_private.fn_photo_access(name));
create policy frightnight_photo_select on storage.objects for select to authenticated using(bucket_id='frightnight-zone-photos' and app_private.fn_photo_access(name));
create policy frightnight_photo_delete on storage.objects for delete to authenticated using(bucket_id='frightnight-zone-photos' and app_private.fn_photo_access(name));
-- Closed private storage: no direct API table access, even for authenticated users.
do $$ declare x record; begin
 for x in select tablename from pg_tables where schemaname='app_private' and tablename like 'fn\_%' escape '\' loop
  execute format('alter table app_private.%I enable row level security',x.tablename);
  execute format('revoke all on app_private.%I from public,anon,authenticated,service_role',x.tablename);
 end loop;
 for x in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where (n.nspname='app_private' and p.proname like 'fn\_%' escape '\') or (n.nspname='api' and p.proname like 'frightnight\_%' escape '\') loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',x.signature);
 end loop;
end $$;
grant execute on function api.frightnight_snapshot(text),api.frightnight_command(text,text,jsonb,uuid),api.frightnight_walk(text,uuid) to authenticated;
grant execute on function api.frightnight_payment_create(text,uuid,uuid),api.frightnight_payment_bind(text,uuid,text,text),api.frightnight_payment_lookup(text,text),api.frightnight_payment_for_actor(text,uuid),api.frightnight_payment_confirm(text,text,text,integer,text,text,jsonb),api.frightnight_payment_test_order(text,uuid,uuid,uuid),api.frightnight_payment_for_refund(text,uuid,uuid,uuid,text),api.frightnight_payment_refund_record(text,uuid,uuid,text,text,uuid,text),api.frightnight_bootstrap(text,uuid,text,text) to service_role;

grant execute on function app_private.fn_photo_access(text) to authenticated;

grant execute on function api.frightnight_admin_list(text,text,integer,integer,text,jsonb) to authenticated;

grant execute on function api.frightnight_payment_scope(text) to service_role;

grant execute on function api.frightnight_initialize(text,uuid,text),api.frightnight_public_content(text) to service_role;
