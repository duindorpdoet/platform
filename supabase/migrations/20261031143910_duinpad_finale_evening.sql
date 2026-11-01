-- Additive only. Business receipts are independent of physical show attempts.
set lock_timeout='5s';
create table app_private.duinpad_evenings(
 run_id uuid primary key references app_private.group_runs(id),
 event_id uuid not null references app_private.events(id),
 group_id uuid not null references app_private.walking_groups(id),
 finale_stop_id uuid not null references app_private.run_stops(id),
 first_finale_scan_at timestamptz not null,
 evening_ends_at timestamptz not null,
 processed_at timestamptz,
 check(evening_ends_at=first_finale_scan_at+interval '2 hours')
);
-- Frozen cohort: accepted adults of households with an active, present child in
-- this run at the first scan. Early departures are excluded. Reassignment and
-- party changes never move a cohort/deadline. One account has one event evening.
create table app_private.duinpad_evening_members(
 event_id uuid not null references app_private.events(id),
 account_id uuid not null references auth.users(id),
 run_id uuid not null references app_private.duinpad_evenings(run_id),
 registration_id uuid not null references app_private.registrations(id),
 household_id uuid not null references app_private.households(id),
 captured_at timestamptz not null,
 primary key(event_id,account_id)
);
create table app_private.duinpad_finale_receipts(
 id uuid primary key default gen_random_uuid(),
 event_id uuid not null references app_private.events(id),
 run_id uuid not null references app_private.group_runs(id),
 group_id uuid not null references app_private.walking_groups(id),
 run_stop_id uuid not null references app_private.run_stops(id),
 actor_id uuid not null references auth.users(id),
 party_id uuid references app_private.together_parties(id),
 scan_unit text not null,
 credential_id uuid not null references app_private.portal_credentials(id),
 recorded_at timestamptz not null,
 unique(event_id,scan_unit),
 check(scan_unit=case when party_id is null then 'account:'||actor_id::text else 'party:'||party_id::text end)
);
create table app_private.duinpad_finale_account_claims(
 event_id uuid not null references app_private.events(id),account_id uuid not null references auth.users(id),
 receipt_id uuid not null references app_private.duinpad_finale_receipts(id),primary key(event_id,account_id)
);
create table app_private.duinpad_finale_registration_claims(
 event_id uuid not null references app_private.events(id),registration_id uuid not null references app_private.registrations(id),
 receipt_id uuid not null references app_private.duinpad_finale_receipts(id),primary key(event_id,registration_id)
);
create table app_private.duinpad_finale_party_claims(
 event_id uuid not null references app_private.events(id),party_id uuid not null references app_private.together_parties(id),
 receipt_id uuid not null references app_private.duinpad_finale_receipts(id),primary key(event_id,party_id)
);
create index duinpad_evenings_due on app_private.duinpad_evenings(evening_ends_at) where processed_at is null;
create index duinpad_evening_members_run on app_private.duinpad_evening_members(run_id);

create function app_private.duinpad_immutable() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'DUINPAD_HISTORY_IMMUTABLE' using errcode='23514'; end $$;
create function app_private.duinpad_evening_immutable() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' or (to_jsonb(new)-'processed_at') is distinct from (to_jsonb(old)-'processed_at')
  or(old.processed_at is not null and new.processed_at is distinct from old.processed_at)
 then raise exception 'DUINPAD_HISTORY_IMMUTABLE' using errcode='23514';end if;
 return new;
end $$;
create trigger duinpad_evening_immutable before update or delete on app_private.duinpad_evenings for each row execute function app_private.duinpad_evening_immutable();
do $$declare t text;begin
 foreach t in array array['duinpad_evenings','duinpad_evening_members','duinpad_finale_receipts','duinpad_finale_account_claims','duinpad_finale_registration_claims','duinpad_finale_party_claims'] loop
  execute format('alter table app_private.%I enable row level security',t);
  execute format('revoke all on app_private.%I from public,anon,authenticated',t);
  if t<>'duinpad_evenings' then execute format('create trigger duinpad_history_immutable before update or delete on app_private.%I for each row execute function app_private.duinpad_immutable()',t);end if;
 end loop;
end $$;

create function app_private.duinpad_receipt_for_actor(_event uuid,_actor uuid) returns uuid
language sql stable security definer set search_path='' as $$
 with own as(select r.id from app_private.registrations r where r.event_id=_event and app_private.is_household_member(r.household_id,_actor)),
 candidates as(
  select c.receipt_id from app_private.duinpad_finale_account_claims c where c.event_id=_event and c.account_id=_actor
  union select c.receipt_id from app_private.duinpad_finale_registration_claims c join own on own.id=c.registration_id where c.event_id=_event
  union select c.receipt_id from own join app_private.together_memberships m on m.registration_id=own.id
   join app_private.duinpad_finale_party_claims c on c.party_id=m.party_id and c.event_id=_event
   join app_private.duinpad_finale_receipts receipt on receipt.id=c.receipt_id
   where m.left_at is null or m.left_at>=receipt.recorded_at
  -- A new merged party cannot turn an already used household into a fresh unit.
  union select c.receipt_id from own join app_private.together_memberships m on m.registration_id=own.id and m.left_at is null
   join app_private.together_memberships peer on peer.party_id=m.party_id and peer.left_at is null
   join app_private.duinpad_finale_registration_claims c on c.registration_id=peer.registration_id and c.event_id=_event
 ) select r.id from candidates c join app_private.duinpad_finale_receipts r on r.id=c.receipt_id order by r.recorded_at,r.id limit 1
$$;

create function app_private.duinpad_run_for_actor(_event uuid,_actor uuid) returns uuid
language sql stable security definer set search_path='' as $$
 select coalesce(
  (select r.run_id from app_private.duinpad_finale_receipts r where r.id=app_private.duinpad_receipt_for_actor(_event,_actor)),
  (select m.run_id from app_private.duinpad_evening_members m where m.event_id=_event and m.account_id=_actor),
  (select run.id from app_private.registrations reg
   join app_private.group_registrations a on a.registration_id=reg.id and a.superseded_at is null
   join app_private.walking_groups g on g.id=a.group_id and g.event_id=_event and g.retired_at is null
   join app_private.group_runs run on run.group_id=g.id
   where reg.event_id=_event and reg.status='submitted' and app_private.is_household_member(reg.household_id,_actor)
   and exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id where rp.run_id=run.id and rc.registration_id=reg.id)
   order by run.created_at desc,run.id limit 1))
$$;

create function app_private.duinpad_finale_scope(_event uuid,_run uuid,_actor uuid) returns table(registration_id uuid)
language sql stable security definer set search_path='' as $$
 with own as(select r.id from app_private.registrations r where r.event_id=_event and r.status='submitted' and app_private.is_household_member(r.household_id,_actor)),
 units as(select own.id from own union select peer.registration_id from own
  join app_private.together_memberships m on m.registration_id=own.id and m.left_at is null
  join app_private.together_memberships peer on peer.party_id=m.party_id and peer.left_at is null)
 select distinct units.id from units join app_private.registration_children rc on rc.registration_id=units.id and rc.participation_status='active'
 join app_private.run_participants rp on rp.registration_child_id=rc.id and rp.run_id=_run and rp.attendance='present' and rp.departed_at is null
$$;

create function api.duinpad_finale_snapshot(_event_slug text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare eid uuid; r app_private.group_runs; s app_private.run_stops; receipt app_private.duinpad_finale_receipts;
 evening app_private.duinpad_evenings; pid uuid; eligible boolean:=false; own_early boolean:=false; finished boolean:=false; location jsonb;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select id into eid from app_private.events where slug=_event_slug;
 if eid is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into r from app_private.group_runs where id=app_private.duinpad_run_for_actor(eid,auth.uid());
 if r.id is null then return jsonb_build_object('eligible',false,'recorded',false,'eveningEnded',app_private.duinpad_evening_closed(eid,auth.uid()),'children','[]'::jsonb);end if;
 select * into receipt from app_private.duinpad_finale_receipts where id=app_private.duinpad_receipt_for_actor(eid,auth.uid());
 select * into evening from app_private.duinpad_evenings where run_id=r.id;
 select final_portal_id into pid from app_private.event_route_settings where event_id=eid;
 select stop.* into s from app_private.run_stops stop left join app_private.route_plan_stops plan on plan.id=stop.plan_stop_id
  where stop.run_id=r.id and stop.stop_kind='finale' and coalesce(stop.portal_id,plan.portal_id)=pid
   and(stop.id=r.current_stop_id and stop.state='active' or stop.id=evening.finale_stop_id and stop.state='completed')
  order by stop.sequence limit 1;
 own_early:=exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id
   join app_private.registrations reg on reg.id=rc.registration_id where rp.run_id=r.id and rp.departure_reason='early' and app_private.is_household_member(reg.household_id,auth.uid()))
  and not exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id
   join app_private.registrations reg on reg.id=rc.registration_id where rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null and app_private.is_household_member(reg.household_id,auth.uid()));
 finished:=own_early or app_private.duinpad_evening_closed(eid,auth.uid()) or(evening.run_id is not null and evening.evening_ends_at<=statement_timestamp());
 eligible:=not finished and s.id is not null and receipt.id is null and r.status in('live','completed')
  and exists(select 1 from app_private.duinpad_finale_scope(eid,r.id,auth.uid()))
  and exists(select 1 from app_private.portals p where p.id=pid and p.operation_status in('open','paused'));
 if (eligible or receipt.id is not null) and not finished then
  select jsonb_build_object('name',p.name,'address',concat_ws(' ',l.street,l.house_number,l.addition),'instruction',app_private.portal_public_entrance(p.id))
   into location from app_private.portals p left join app_private.portal_private_locations l on l.portal_id=p.id where p.id=pid;
 end if;
 return jsonb_build_object('eventId',eid,'eligible',eligible,'recorded',receipt.id is not null,'receiptId',receipt.id,
  'runId',r.id,'groupId',r.group_id,'relayGroupId',r.id::text,'finaleStopId',s.id,'portalId',case when eligible or receipt.id is not null then pid end,
  'runVersion',r.version,'firstFinaleScanAt',evening.first_finale_scan_at,'eveningEndsAt',evening.evening_ends_at,
  'eveningEnded',finished,'location',location,'children',coalesce((select jsonb_agg(jsonb_build_object('id',rp.id,'name',c.first_name,'status',st.status) order by c.first_name,rp.id)
   from app_private.duinpad_finale_scope(eid,r.id,auth.uid()) scope join app_private.registration_children rc on rc.registration_id=scope.registration_id and rc.participation_status='active'
   join app_private.run_participants rp on rp.registration_child_id=rc.id and rp.run_id=r.id and rp.attendance='present' and rp.departed_at is null
   join app_private.children c on c.id=rc.child_id left join app_private.stop_participant_statuses st on st.run_stop_id=s.id and st.run_participant_id=rp.id),'[]'::jsonb));
end $$;

create function app_private.duinpad_finale_credential(_event_slug text,_credential text,_portal_id uuid,_method text) returns uuid
language plpgsql security definer set search_path='' as $$
declare context jsonb; cid uuid;
begin
 context:=api.duinpad_finale_snapshot(_event_slug);
 if coalesce((context->>'eveningEnded')::boolean,false) then raise exception 'EVENING_ENDED' using errcode='23514';end if;
 if not coalesce((context->>'eligible')::boolean,false) and not coalesce((context->>'recorded')::boolean,false) then raise exception 'FINALE_NOT_RELEASED' using errcode='42501';end if;
 if _method not in('qr','short_code') or char_length(coalesce(_credential,'')) not between 4 and 160
  or(_portal_id is not null and _portal_id is distinct from (context->>'portalId')::uuid) then raise exception 'WRONG_PORTAL' using errcode='22023';end if;
 select c.id into cid from app_private.portal_credentials c where c.portal_id=(context->>'portalId')::uuid
  and c.revoked_at is null and c.valid_from<=statement_timestamp() and(c.valid_until is null or c.valid_until>statement_timestamp())
  and((_method='qr' and c.token_hash=extensions.digest(convert_to(_credential,'utf8'),'sha256'))
   or(_method='short_code' and c.short_code_hash=extensions.digest(convert_to(upper(trim(_credential)),'utf8'),'sha256')))
  order by c.version desc limit 1;
 if cid is null then raise exception 'WRONG_PORTAL' using errcode='22023';end if;
 return cid;
end $$;

create function api.duinpad_finale_validate(_event_slug text,_credential text,_portal_id uuid default null,_method text default 'qr') returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.duinpad_finale_credential(_event_slug,_credential,_portal_id,_method);
 return api.duinpad_finale_snapshot(_event_slug)||jsonb_build_object('valid',true);
end $$;

create function app_private.duinpad_finale_record(_event_slug text,_credential_id uuid,_participant_choices jsonb,_idempotency_key text,_method text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid; rid uuid; r app_private.group_runs; s app_private.run_stops; cid uuid; pid uuid;
 receipt app_private.duinpad_finale_receipts; party uuid; own_reg uuid; registration_ids uuid[]; account_ids uuid[];
 recorded timestamptz; evidenceid uuid; result jsonb; visited_count integer; skipped_count integer; v_outcome app_private.stop_outcome;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if char_length(coalesce(_idempotency_key,'')) not between 8 and 100 then raise exception 'IDEMPOTENCY_KEY_REQUIRED' using errcode='22023';end if;
 select id into eid from app_private.events where slug=_event_slug;
 if eid is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 -- Serialize account/party merges and all first scans. This narrow event lock is
 -- held only for DB work; never while contacting relay, QLC, audio or mail.
 perform pg_advisory_xact_lock(hashtextextended(eid::text||':duinpad-finale',0));
 perform 1 from app_private.events where id=eid for update;
 rid:=app_private.duinpad_run_for_actor(eid,auth.uid());
 select * into r from app_private.group_runs where id=rid for update;
 if r.id is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into receipt from app_private.duinpad_finale_receipts where id=app_private.duinpad_receipt_for_actor(eid,auth.uid());
 if receipt.id is not null then
  return api.duinpad_finale_snapshot(_event_slug)||jsonb_build_object('duplicate',true,'receiptId',receipt.id,'accepted',true,'completedStopId',receipt.run_stop_id);
 end if;
 if coalesce((api.duinpad_finale_snapshot(_event_slug)->>'eveningEnded')::boolean,false) then raise exception 'EVENING_ENDED' using errcode='23514';end if;
 cid:=_credential_id;
 select final_portal_id into pid from app_private.event_route_settings where event_id=eid;
 if _method not in('qr','short_code') or not exists(select 1 from app_private.portal_credentials c where c.id=cid and c.portal_id=pid and c.revoked_at is null and c.valid_from<=statement_timestamp() and(c.valid_until is null or c.valid_until>statement_timestamp())) then raise exception 'WRONG_PORTAL' using errcode='22023';end if;
 select stop.* into s from app_private.run_stops stop left join app_private.route_plan_stops plan on plan.id=stop.plan_stop_id
  where stop.run_id=rid and stop.stop_kind='finale' and coalesce(stop.portal_id,plan.portal_id)=pid
   and(stop.id=r.current_stop_id and stop.state='active' or exists(select 1 from app_private.duinpad_evenings e where e.run_id=rid and e.finale_stop_id=stop.id and stop.state='completed'))
  order by stop.sequence limit 1 for update of stop;
 if s.id is null then raise exception 'FINALE_NOT_RELEASED' using errcode='42501';end if;
 select array_agg(registration_id) into registration_ids from app_private.duinpad_finale_scope(eid,rid,auth.uid());
 if cardinality(registration_ids) is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if jsonb_typeof(_participant_choices) is distinct from 'object' or _participant_choices='{}'::jsonb
  or exists(select 1 from jsonb_each_text(_participant_choices) c where c.value not in('visited','skipped') or not exists(
    select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id
    where rp.id::text=c.key and rp.run_id=rid and rp.attendance='present' and rp.departed_at is null and rc.participation_status='active' and rc.registration_id=any(registration_ids)))
  or exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id
   where rp.run_id=rid and rp.attendance='present' and rp.departed_at is null and rc.participation_status='active' and rc.registration_id=any(registration_ids) and not(_participant_choices ? rp.id::text))
 then raise exception 'INVALID_ATTENDANCE' using errcode='22023';end if;
 select reg.id into own_reg from app_private.registrations reg where reg.id=any(registration_ids) and app_private.is_household_member(reg.household_id,auth.uid()) order by reg.id limit 1;
 select m.party_id into party from app_private.together_memberships m where m.registration_id=own_reg and m.left_at is null;
 -- Lock party/membership rows as well as the run; party administration cannot
 -- change the accepted unit between its resolution and persistence.
 perform 1 from app_private.together_parties p where p.id=party for update;
 perform 1 from app_private.together_memberships m where m.registration_id=any(registration_ids) for share;
 recorded:=clock_timestamp();
 -- Lock waits may outlive a deadline even when validation began before it.
 if exists(select 1 from app_private.duinpad_evenings evening where evening.run_id=rid and evening.evening_ends_at<=recorded)
 or exists(select 1 from app_private.duinpad_evening_members member join app_private.duinpad_evenings evening on evening.run_id=member.run_id
  where member.event_id=eid and member.account_id=auth.uid() and evening.evening_ends_at<=recorded)
 then raise exception 'EVENING_ENDED' using errcode='23514';end if;
 if exists(select 1 from app_private.portal_credentials c where c.id=cid and(c.revoked_at is not null or c.valid_from>recorded or c.valid_until<=recorded))
 then raise exception 'WRONG_PORTAL' using errcode='22023';end if;
 insert into app_private.duinpad_evenings(run_id,event_id,group_id,finale_stop_id,first_finale_scan_at,evening_ends_at)
  values(rid,eid,r.group_id,s.id,recorded,recorded+interval '2 hours') on conflict(run_id) do nothing;
 insert into app_private.duinpad_evening_members(event_id,account_id,run_id,registration_id,household_id,captured_at)
  select distinct on(m.user_id) eid,m.user_id,rid,reg.id,reg.household_id,recorded
  from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id and rc.participation_status='active'
  join app_private.registrations reg on reg.id=rc.registration_id and reg.status='submitted'
  join app_private.household_members m on m.household_id=reg.household_id and m.revoked_at is null and m.accepted_at is not null
  join app_private.duinpad_evenings evening on evening.run_id=rid and evening.first_finale_scan_at=recorded
  where rp.run_id=rid and rp.attendance='present' and rp.departed_at is null order by m.user_id,reg.id on conflict do nothing;
 if party is null then account_ids:=array[auth.uid()];
 else select array_agg(distinct m.user_id) into account_ids from app_private.registrations reg
  join app_private.household_members m on m.household_id=reg.household_id and m.revoked_at is null and m.accepted_at is not null where reg.id=any(registration_ids);end if;
 insert into app_private.duinpad_finale_receipts(event_id,run_id,group_id,run_stop_id,actor_id,party_id,scan_unit,credential_id,recorded_at)
  values(eid,rid,r.group_id,s.id,auth.uid(),party,case when party is null then 'account:'||auth.uid()::text else 'party:'||party::text end,cid,recorded) returning * into receipt;
 insert into app_private.duinpad_finale_account_claims select eid,a,receipt.id from unnest(account_ids||array[auth.uid()]) a group by a;
 if party is not null then
  insert into app_private.duinpad_finale_registration_claims select eid,a,receipt.id from unnest(registration_ids) a;
  insert into app_private.duinpad_finale_party_claims values(eid,party,receipt.id);
 end if;
 insert into app_private.scan_evidence(run_stop_id,credential_id,credential_version,actor_id,validation_method)
  select s.id,cid,c.version,auth.uid(),_method from app_private.portal_credentials c where c.id=cid on conflict(run_stop_id) do nothing;
 select id into evidenceid from app_private.scan_evidence where run_stop_id=s.id;
 insert into app_private.stop_participant_statuses(run_stop_id,run_participant_id,status,changed_by,decided_at)
  select s.id,c.key::uuid,c.value::app_private.participant_stop_status,auth.uid(),recorded from jsonb_each_text(_participant_choices) c
  on conflict(run_stop_id,run_participant_id) do update set status=excluded.status,changed_by=excluded.changed_by,decided_at=excluded.decided_at,version=app_private.stop_participant_statuses.version+1;
 insert into app_private.run_stop_arrivals(event_id,run_id,run_stop_id,run_participant_id,child_id,scan_evidence_id,arrived,arrived_at,actor_id)
  select eid,rid,s.id,rp.id,rc.child_id,evidenceid,true,recorded,auth.uid() from jsonb_each_text(_participant_choices) c
  join app_private.run_participants rp on rp.id=c.key::uuid join app_private.registration_children rc on rc.id=rp.registration_child_id on conflict do nothing;
 select count(*) filter(where value='visited'),count(*) filter(where value='skipped') into visited_count,skipped_count from jsonb_each_text(_participant_choices);
 v_outcome:=case when visited_count>0 and skipped_count>0 then 'mixed'::app_private.stop_outcome when visited_count>0 then 'visited'::app_private.stop_outcome else 'all_skipped'::app_private.stop_outcome end;
 if s.state='active' then
  update app_private.run_stops set state='completed',outcome=v_outcome,completed_at=recorded,completion_actor=auth.uid(),version=version+1 where id=s.id;
  update app_private.portal_reservations set status='completed',version=version+1 where id=s.reservation_id;
  insert into app_private.group_seals(run_id,run_stop_id,world_id,outcome) select rid,s.id,p.world_id,v_outcome from app_private.portals p where p.id=pid on conflict(run_stop_id) do nothing;
  update app_private.group_runs set status='completed',current_stop_id=null,finished_at=recorded,version=version+1 where id=rid;
  update app_private.walking_groups set status='completed',version=version+1 where id=r.group_id;
 end if;
 -- The completed-stop trigger covers the first cohort; later independently
 -- authorized accounts award only their own proven arrivals, on the saved stop.
 perform app_private.record_arrival_seals(s.id);
 insert into app_private.journey_events(run_id,stop_id,event_type,actor_id,safe_metadata)
  values(rid,s.id,'duinpad.finale_recorded',auth.uid(),jsonb_build_object('receiptId',receipt.id,'party',party is not null));
 insert into app_private.audit_events(event_id,actor_id,action,resource_type,resource_id,minimal_change)
  values(eid,auth.uid(),'duinpad.finale_recorded','finale_receipt',receipt.id,jsonb_build_object('runId',rid));
 result:=api.duinpad_finale_snapshot(_event_slug)||jsonb_build_object('duplicate',false,'receiptId',receipt.id,'accepted',true,'completedStopId',s.id);
 return result;
end $$;

-- A frozen finished cohort follows the account across later reassignment.
-- Voluntary whole-household departure is also permanent for this event.
create function app_private.duinpad_evening_closed(_event uuid,_actor uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.duinpad_evening_members m join app_private.duinpad_evenings e on e.run_id=m.run_id
  where m.event_id=_event and m.account_id=_actor and e.evening_ends_at<=statement_timestamp())
 or exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id
  join app_private.registrations reg on reg.id=rc.registration_id where reg.event_id=_event and rp.departure_reason='early'
  and app_private.is_household_member(reg.household_id,_actor) and not exists(select 1 from app_private.run_participants other
   join app_private.registration_children other_rc on other_rc.id=other.registration_child_id
   join app_private.registrations other_reg on other_reg.id=other_rc.registration_id
   where other.run_id=rp.run_id and other.attendance='present' and other.departed_at is null and app_private.is_household_member(other_reg.household_id,_actor)))
$$;
create function app_private.duinpad_assert_evening_open(_event uuid) returns void
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if app_private.duinpad_evening_closed(_event,auth.uid()) then raise exception 'EVENING_ENDED' using errcode='23514';end if;
end $$;
alter function api.run_start(uuid,uuid[],integer,text,text) rename to run_start_before_duinpad;
create function api.run_start(_group_id uuid,_present_registration_child_ids uuid[],_expected_group_version integer,_idempotency_key text,_request_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.duinpad_assert_evening_open((select event_id from app_private.walking_groups where id=_group_id));
 return api.run_start_before_duinpad(_group_id,_present_registration_child_ids,_expected_group_version,_idempotency_key,_request_hash);
end $$;
alter function api.run_scan(uuid,uuid,integer,text,text) rename to run_scan_before_duinpad;
create function api.run_scan(_run_id uuid,_expected_stop_id uuid,_expected_run_version integer,_credential text,_method text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.duinpad_assert_evening_open((select g.event_id from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id where r.id=_run_id));
 return api.run_scan_before_duinpad(_run_id,_expected_stop_id,_expected_run_version,_credential,_method);
end $$;
alter function api.run_set_state(uuid,app_private.run_status,integer,text) rename to run_set_state_before_duinpad;
create function api.run_set_state(_run_id uuid,_state app_private.run_status,_expected_version integer,_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if _state='live' then perform app_private.duinpad_assert_evening_open((select g.event_id from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id where r.id=_run_id));end if;
 return api.run_set_state_before_duinpad(_run_id,_state,_expected_version,_reason);
end $$;
revoke all on function app_private.duinpad_evening_closed(uuid,uuid),app_private.duinpad_assert_evening_open(uuid),api.run_start_before_duinpad(uuid,uuid[],integer,text,text),api.run_scan_before_duinpad(uuid,uuid,integer,text,text),api.run_set_state_before_duinpad(uuid,app_private.run_status,integer,text) from public,anon,authenticated;
revoke all on function api.run_start(uuid,uuid[],integer,text,text),api.run_scan(uuid,uuid,integer,text,text),api.run_set_state(uuid,app_private.run_status,integer,text) from public,anon;
grant execute on function api.run_start(uuid,uuid[],integer,text,text),api.run_scan(uuid,uuid,integer,text,text),api.run_set_state(uuid,app_private.run_status,integer,text) to authenticated;

-- Current and pre-release clients use the same business transaction. These
-- adapters retain existing leader checks, filter old group choices to the own
-- account/party, and never contact or enqueue the show. Thus arrival recovery
-- can restore a business receipt without issuing a fresh physical command.
create function api.duinpad_finale_confirm(_event_slug text,_credential text,_participant_choices jsonb,_idempotency_key text,_portal_id uuid default null,_method text default 'qr') returns jsonb
language plpgsql security definer set search_path='' as $$
declare eid uuid; existing uuid; cid uuid;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select id into eid from app_private.events where slug=_event_slug;
 existing:=app_private.duinpad_receipt_for_actor(eid,auth.uid());
 if existing is not null then
  return api.duinpad_finale_snapshot(_event_slug)||jsonb_build_object('duplicate',true,'accepted',true,'receiptId',existing,'completedStopId',(select run_stop_id from app_private.duinpad_finale_receipts where id=existing));
 end if;
 cid:=app_private.duinpad_finale_credential(_event_slug,_credential,_portal_id,_method);
 return app_private.duinpad_finale_record(_event_slug,cid,_participant_choices,_idempotency_key,_method);
end $$;

create function app_private.duinpad_legacy_finale(_run uuid,_stop uuid) returns text
language plpgsql stable security definer set search_path='' as $$
declare slug text; eid uuid;
begin
 select e.slug,e.id into slug,eid from app_private.run_stops s join app_private.group_runs r on r.id=s.run_id
  join app_private.walking_groups g on g.id=r.group_id join app_private.events e on e.id=g.event_id
  where s.id=_stop and r.id=_run and s.stop_kind='finale';
 if slug is null then return null;end if;
 if not exists(select 1 from app_private.group_runs r where r.id=_run and app_private.is_current_leader(r.group_id,auth.uid()))
  or app_private.duinpad_run_for_actor(eid,auth.uid()) is distinct from _run then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 return slug;
end $$;
create function app_private.duinpad_legacy_choices(_event uuid,_run uuid,_choices jsonb) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_object_agg(c.key,c.value),'{}'::jsonb) from jsonb_each_text(_choices)c
 where exists(select 1 from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id
  join app_private.duinpad_finale_scope(_event,_run,auth.uid()) scope on scope.registration_id=rc.registration_id
  where rp.id::text=c.key and rp.run_id=_run)
$$;

alter function api.run_confirm_arrival(uuid,uuid,integer,text,jsonb,text,uuid,text) rename to run_confirm_arrival_before_duinpad;
create function api.run_confirm_arrival(_run_id uuid,_expected_stop_id uuid,_expected_run_version integer,_credential text,_participant_choices jsonb,_idempotency_key text,_portal_id uuid default null,_method text default 'qr') returns jsonb
language plpgsql security definer set search_path='' as $$
declare eventslug text;eid uuid;choices jsonb;
begin
 eventslug:=app_private.duinpad_legacy_finale(_run_id,_expected_stop_id);
 if eventslug is not null and jsonb_typeof(_participant_choices)='object' and _participant_choices<>'{}'::jsonb then
  select id into eid from app_private.events where events.slug=eventslug;
  choices:=app_private.duinpad_legacy_choices(eid,_run_id,_participant_choices);
  return api.duinpad_finale_confirm(eventslug,_credential,choices,_idempotency_key,_portal_id,_method);
 end if;
 return api.run_confirm_arrival_before_duinpad(_run_id,_expected_stop_id,_expected_run_version,_credential,_participant_choices,_idempotency_key,_portal_id,_method);
end $$;
alter function api.run_arrive_and_advance(uuid,uuid,integer,text,jsonb,text,uuid,text) rename to run_arrive_and_advance_before_duinpad;
create function api.run_arrive_and_advance(_run_id uuid,_expected_stop_id uuid,_expected_run_version integer,_credential text,_participant_choices jsonb,_idempotency_key text,_portal_id uuid default null,_method text default 'qr') returns jsonb
language plpgsql security definer set search_path='' as $$
declare eventslug text;eid uuid;choices jsonb;
begin
 eventslug:=app_private.duinpad_legacy_finale(_run_id,_expected_stop_id);
 if eventslug is not null then
  select id into eid from app_private.events where events.slug=eventslug;
  choices:=app_private.duinpad_legacy_choices(eid,_run_id,_participant_choices);
  return api.duinpad_finale_confirm(eventslug,_credential,choices,_idempotency_key,_portal_id,_method);
 end if;
 return api.run_arrive_and_advance_before_duinpad(_run_id,_expected_stop_id,_expected_run_version,_credential,_participant_choices,_idempotency_key,_portal_id,_method);
end $$;
alter function api.run_complete_stop(uuid,uuid,integer,boolean,text,text) rename to run_complete_stop_before_duinpad;
create function api.run_complete_stop(_run_id uuid,_stop_id uuid,_expected_run_version integer,_all_skip_confirmed boolean,_idempotency_key text,_request_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare eventslug text;eid uuid;choices jsonb;evidence app_private.scan_evidence;
begin
 eventslug:=app_private.duinpad_legacy_finale(_run_id,_stop_id);
 if eventslug is not null then
  select id into eid from app_private.events where events.slug=eventslug;
  select * into evidence from app_private.scan_evidence where run_stop_id=_stop_id;
  choices:=app_private.duinpad_legacy_choices(eid,_run_id,coalesce((select jsonb_object_agg(run_participant_id::text,status::text) from app_private.stop_participant_statuses where run_stop_id=_stop_id),'{}'::jsonb));
  return app_private.duinpad_finale_record(eventslug,evidence.credential_id,choices,_idempotency_key,evidence.validation_method);
 end if;
 perform app_private.duinpad_assert_evening_open((select g.event_id from app_private.group_runs r join app_private.walking_groups g on g.id=r.group_id where r.id=_run_id));
 return api.run_complete_stop_before_duinpad(_run_id,_stop_id,_expected_run_version,_all_skip_confirmed,_idempotency_key,_request_hash);
end $$;
revoke all on function app_private.duinpad_finale_record(text,uuid,jsonb,text,text),app_private.duinpad_legacy_finale(uuid,uuid),app_private.duinpad_legacy_choices(uuid,uuid,jsonb),
 api.run_confirm_arrival_before_duinpad(uuid,uuid,integer,text,jsonb,text,uuid,text),api.run_arrive_and_advance_before_duinpad(uuid,uuid,integer,text,jsonb,text,uuid,text),
 api.run_complete_stop_before_duinpad(uuid,uuid,integer,boolean,text,text) from public,anon,authenticated;
revoke all on function api.run_confirm_arrival(uuid,uuid,integer,text,jsonb,text,uuid,text),api.run_arrive_and_advance(uuid,uuid,integer,text,jsonb,text,uuid,text),api.run_complete_stop(uuid,uuid,integer,boolean,text,text) from public,anon;
grant execute on function api.run_confirm_arrival(uuid,uuid,integer,text,jsonb,text,uuid,text),api.run_arrive_and_advance(uuid,uuid,integer,text,jsonb,text,uuid,text),api.run_complete_stop(uuid,uuid,integer,boolean,text,text) to authenticated;

-- Business completion is exact +2h; processed_at records worker lag separately.
-- This worker only changes app state and the durable MAIL outbox. No SHOW queue.
create function api.worker_duinpad_evenings(_batch_size integer default 100) returns jsonb
language plpgsql security definer set search_path='' as $$
declare evening app_private.duinpad_evenings; recipient record; processed integer:=0; queued integer:=0; inserted integer;
begin
 for evening in select * from app_private.duinpad_evenings where processed_at is null and evening_ends_at<=statement_timestamp()
  order by evening_ends_at,run_id limit least(greatest(_batch_size,1),500) for update skip locked loop
  for recipient in select m.account_id,lower(trim(u.email)) email from app_private.duinpad_evening_members m
   join auth.users u on u.id=m.account_id and u.email_confirmed_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<=statement_timestamp())
   where m.run_id=evening.run_id and nullif(trim(u.email),'') is not null loop
   insert into app_private.email_outbox(dedupe_key,message_type,recipient_ref,recipient_email,payload,next_attempt_at)
    values('duinpad-evening:'||evening.event_id||':'||recipient.account_id,'duinpad_evening_thanks',recipient.account_id::text,recipient.email,
     jsonb_build_object('eventId',evening.event_id,'runId',evening.run_id,'logicalDueAt',evening.evening_ends_at,'actionPath','/omgeving/meeloper'),evening.evening_ends_at)
    on conflict(dedupe_key) do nothing;
   get diagnostics inserted=row_count;queued:=queued+inserted;
  end loop;
  update app_private.duinpad_evenings set processed_at=clock_timestamp() where run_id=evening.run_id;
  insert into app_private.audit_events(event_id,action,resource_type,resource_id,minimal_change)
   values(evening.event_id,'duinpad.evening_closed','group_run',evening.run_id,jsonb_build_object('logicalDueAt',evening.evening_ends_at));
  processed:=processed+1;
 end loop;
 return jsonb_build_object('processed',processed,'queued',queued);
end $$;

-- Retain the existing minute worker and all its normal dispatch behavior.
alter function app_private.dispatch_all_due_routes() rename to dispatch_all_due_routes_before_duinpad;
create function app_private.dispatch_all_due_routes() returns void language plpgsql security definer set search_path='' as $$
begin
 perform app_private.dispatch_all_due_routes_before_duinpad();
 perform api.worker_duinpad_evenings(100);
end $$;

alter function api.group_snapshot(uuid) rename to group_snapshot_before_duinpad;
create function api.group_snapshot(_group_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; ending jsonb; eid uuid;
begin
 result:=api.group_snapshot_before_duinpad(_group_id);eid:=(result->>'eventId')::uuid;
 ending:=api.duinpad_finale_snapshot((select slug from app_private.events where id=eid));
 if (ending->>'groupId')::uuid=_group_id then result:=result||jsonb_build_object('duinpadFinale',ending);
 elsif coalesce((ending->>'eveningEnded')::boolean,false) then result:=result||jsonb_build_object('duinpadFinale',jsonb_build_object('eveningEnded',true));end if;
 if result->'run' is not null and result->'run'<>'null'::jsonb then
  -- Finished is personal. Do not expose the old cohort's private destination to
  -- a new group/viewer, but do carry this actor's immutable evening state.
  result:=jsonb_set(result,'{run,eveningEnded}',ending->'eveningEnded');
  result:=jsonb_set(result,'{run,duinpadEveningEnded}',ending->'eveningEnded');
  if coalesce((ending->>'eveningEnded')::boolean,false) then
   result:=jsonb_set(result,'{run,ownEveningFinished}','true');
   result:=jsonb_set(result,'{run,currentStop}','null');
  end if;
 end if;
 return result;
end $$;

alter function api.portal_thanks_snapshot(text,text,uuid) rename to portal_thanks_snapshot_before_duinpad;
create function api.portal_thanks_snapshot(_event_slug text,_scope text default 'family',_portal_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; finale jsonb;
begin
 result:=api.portal_thanks_snapshot_before_duinpad(_event_slug,_scope,_portal_id);
 if _scope='family' then
  finale:=api.duinpad_finale_snapshot(_event_slug);
  if finale->>'eveningEndsAt' is not null then result:=jsonb_set(result,'{finished}',finale->'eveningEnded');end if;
 end if;
 return result;
end $$;

revoke all on function app_private.duinpad_immutable(),app_private.duinpad_evening_immutable(),app_private.duinpad_receipt_for_actor(uuid,uuid),
 app_private.duinpad_run_for_actor(uuid,uuid),app_private.duinpad_finale_scope(uuid,uuid,uuid),app_private.duinpad_finale_credential(text,text,uuid,text),
 app_private.dispatch_all_due_routes_before_duinpad(),api.group_snapshot_before_duinpad(uuid),api.portal_thanks_snapshot_before_duinpad(text,text,uuid)
 from public,anon,authenticated;
revoke all on function api.duinpad_finale_snapshot(text),api.duinpad_finale_validate(text,text,uuid,text),api.duinpad_finale_confirm(text,text,jsonb,text,uuid,text),api.group_snapshot(uuid),api.portal_thanks_snapshot(text,text,uuid) from public,anon;
grant execute on function api.duinpad_finale_snapshot(text),api.duinpad_finale_validate(text,text,uuid,text),api.duinpad_finale_confirm(text,text,jsonb,text,uuid,text),api.group_snapshot(uuid),api.portal_thanks_snapshot(text,text,uuid) to authenticated;
revoke all on function api.worker_duinpad_evenings(integer) from public,anon,authenticated;
grant execute on function api.worker_duinpad_evenings(integer) to service_role;
notify pgrst,'reload schema';

-- Keep the isolated rehearsal on the same canonical finale and own-parent
-- transaction as production. Its P7711 subtransaction rolls back the business
-- receipt, evening, claims, seals and audit evidence along with every fixture.
create or replace function api.redesign_rehearsal(_event_slug text,_scenario text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ownerid uuid:=auth.uid(); realevent uuid; eventid uuid:=gen_random_uuid(); homeid uuid:=gen_random_uuid(); registrationid uuid:=gen_random_uuid();
 groupid uuid:=gen_random_uuid(); planid uuid:=gen_random_uuid(); worldid uuid:=gen_random_uuid(); childids uuid[]:='{}'; rcids uuid[]:='{}'; portalids uuid[]:='{}'; tokens text[]:='{}';
 slotid uuid:=gen_random_uuid(); nodeid uuid; previousnode uuid:=gen_random_uuid(); runid uuid; activeid uuid; r app_private.group_runs; fixtureid uuid; portalid uuid; applicationid uuid; childid uuid; rcid uuid; participantid uuid;
 i integer; n integer; operation jsonb; scenarios jsonb:='{"start": [{"op": "empty", "title": "Start zonder aanwezigen weigeren", "history": 0, "sequence": 0, "status": "before", "seals": [0, 0, 0], "error": "EMPTY_GROUP"}, {"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Twee aanwezige kinderen bereiken de poort", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 0]}, {"op": "snapshot", "title": "Afwezig kind krijgt geen zegel", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 0]}], "arrival": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "snapshot", "title": "Precies de volgende bestemming staat klaar", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "inclusive": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "snapshot", "title": "Buiten blijven krijgt dezelfde aankomstzegel", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "wrong": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "wrong", "title": "Een verkeerde poortcode weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "WRONG_PORTAL"}], "duplicate": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "repeat", "title": "Dezelfde opdracht blijft eenmalig", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "closed": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "close", "title": "Eigen oefenpoort sluiten", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij gesloten poort weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "PORTAL_UNAVAILABLE"}, {"op": "systemskip", "title": "Expliciete systeemoverslag zonder zegel", "history": 1, "sequence": 2, "status": "live", "seals": [0, 0, 0]}], "manual": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "skipall", "title": "Alle kinderen slaan de beleving over", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "complete", "title": "Zonder aankomst niet afronden", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "SCAN_REQUIRED"}, {"op": "scan", "title": "Alleen code bevestigen zonder definitieve zegels", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "complete", "title": "Met aankomst iedereen een zegel geven", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "offline": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "offline", "title": "Verbinding weg: geen serveropdracht ontvangen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Na herstel dezelfde aankomst bevestigen", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "repeat", "title": "Herhaalde ontvangst maakt geen duplicaat", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}], "stale": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "stale", "title": "Oude routeversie weigeren", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0], "error": "STALE_VERSION"}], "early": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Aankomst bij poort 2", "history": 2, "sequence": 3, "status": "live", "seals": [2, 2, 2]}, {"op": "departall", "title": "Eigen gezin sluit af zonder finale", "history": 2, "sequence": 0, "status": "stopped", "seals": [2, 2, 2]}], "part-departure": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "departone", "title": "Een kind vertrekt; de groep loopt door", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Vertrokken kind krijgt geen volgende zegel", "history": 2, "sequence": 3, "status": "live", "seals": [2, 1, 2]}], "finale": [{"op": "start", "title": "Aanwezigheid bevestigen", "history": 0, "sequence": 1, "status": "live", "seals": [0, 0, 0]}, {"op": "arrive", "title": "Aankomst bij poort 1", "history": 1, "sequence": 2, "status": "live", "seals": [1, 1, 1]}, {"op": "arrive", "title": "Aankomst bij poort 2", "history": 2, "sequence": 3, "status": "live", "seals": [2, 2, 2]}, {"op": "arrive", "title": "Aankomst bij poort 3", "history": 3, "sequence": 4, "status": "live", "seals": [3, 3, 3]}, {"op": "arrive", "title": "Aankomst bij poort 4", "history": 4, "sequence": 5, "status": "live", "seals": [4, 4, 4]}, {"op": "arrive", "title": "Finaleaankomst telt ook bij buiten blijven", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}, {"op": "snapshot", "title": "Ieder aanwezig kind heeft precies een finalezegel", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}, {"op": "repeat", "title": "Geen dubbele finale of zesde zegel", "history": 5, "sequence": 0, "status": "completed", "seals": [5, 5, 5]}]}'::jsonb; spec jsonb; report jsonb:='[]'; results jsonb; request jsonb; previous jsonb;
 problem text; currentportal uuid; token text; runversion integer; stopid uuid; leavingids uuid[]; choices jsonb; started timestamptz:=clock_timestamp(); tick timestamptz;
 actualhistory integer; actualseq integer; actualstatus text; sealcounts jsonb; view jsonb; ok boolean;
begin
 select id into realevent from app_private.events where slug=_event_slug;
 if ownerid is null or realevent is null or not (app_private.has_capability(realevent,'live_support',ownerid) or app_private.has_capability(realevent,'event_admin',ownerid)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 spec:=scenarios->_scenario;
 if spec is null then raise exception 'INVALID_SCENARIO'; end if;
 perform pg_advisory_xact_lock(hashtextextended(ownerid::text||':redesign-rehearsal',0));
 begin
  insert into app_private.events(id,slug,title,local_date,phase,price_cents,settings) values(eventid,'rehearsal-'||replace(eventid::text,'-',''),'Geïsoleerde generale',(now() at time zone 'Europe/Amsterdam')::date,'live',0,'{"rehearsal":true}');
  insert into app_private.households(id,label,primary_contact_user_id) values(homeid,'Oefengezin',ownerid);
  insert into app_private.household_members(household_id,user_id,relation_role) values(homeid,ownerid,'owner');
  insert into app_private.registrations(id,event_id,household_id,status,reference) values(registrationid,eventid,homeid,'submitted','LAB-'||registrationid::text);
  for i in 1..3 loop
   insert into app_private.children(household_id,first_name,age_at_event) values(homeid,(array['Oefenkind A','Oefenkind B','Oefenkind C'])[i],8) returning id into childid;
   insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents) values(eventid,registrationid,childid,0) returning id into rcid;
   childids:=array_append(childids,childid);rcids:=array_append(rcids,rcid);
  end loop;
  insert into app_private.start_slots(id,event_id,external_id,name,location_name,private_address,starts_at,max_groups,max_children) values(slotid,eventid,'lab-start','Oefenstart','Oefenlocatie','Geïsoleerd oefenadres',date_bin(interval '10 minutes',now(),'2000-01-01Z'::timestamptz)-interval '1 hour',1,20);
  insert into app_private.walking_nodes(id,event_id,external_id,kind,coordinate,verified_at) values(previousnode,eventid,'lab-start','start',point(4.26,52.10),now());
  for i in 1..5 loop
   worldid:=gen_random_uuid();
   insert into app_private.worlds(id,event_id,slug,name,sort_order) values(worldid,eventid,'oefenwereld-'||i,'Oefenwereld '||i,i);
   applicationid:=gen_random_uuid();portalid:=gen_random_uuid();token:=encode(extensions.gen_random_bytes(32),'hex');
   insert into app_private.portal_applications(id,event_id,applicant_user_id,review_status) values(applicationid,eventid,ownerid,'approved');
   insert into app_private.portals(id,event_id,application_id,world_id,name,intensity,operation_status) values(portalid,eventid,applicationid,worldid,'Oefenpoort '||i,1,'open');
   insert into app_private.portal_owners(portal_id,user_id,role) values(portalid,ownerid,'owner');
   insert into app_private.portal_credentials(portal_id,token_hash,short_code_hash,version,valid_from) values(portalid,extensions.digest(token,'sha256'),extensions.digest(upper(token),'sha256'),1,now()-interval '1 minute');
   insert into app_private.portal_private_locations(portal_id,street,house_number,postal_code,latitude,longitude,verified_at) values(portalid,'Oefenstraat',i::text,'0000XX',52.10,4.26,now());
   insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,max_concurrent_groups,max_children_per_visit) values(portalid,now()-interval '1 hour',now()+interval '5 hours',3,1,20);
   nodeid:=gen_random_uuid();
   insert into app_private.walking_nodes(id,event_id,kind,portal_id,coordinate,verified_at) values(nodeid,eventid,'portal',portalid,point(4.26+i*.0001,52.10),now());
   insert into app_private.walking_edges(event_id,from_node_id,to_node_id,distance_m,duration_seconds,approved_at,approved_by) values(eventid,previousnode,nodeid,10,10,now(),ownerid);
   previousnode:=nodeid;
   portalids:=array_append(portalids,portalid);tokens:=array_append(tokens,token);
  end loop;
  insert into app_private.walking_groups(id,event_id,code,status,start_slot_id) values(groupid,eventid,'LAB-01','ready',slotid);
  insert into app_private.group_leaders(group_id,user_id,active_from,revision) values(groupid,ownerid,now()-interval '1 minute',1);
  insert into app_private.group_registrations(group_id,registration_id,assignment_revision,published_at) values(groupid,registrationid,1,now());
  insert into app_private.route_plan_versions(id,group_id,revision,state,input_hash) values(planid,groupid,1,'draft',eventid::text);
  for i in 1..5 loop
   insert into app_private.route_plan_stops(plan_version_id,position,portal_id,planned_arrival_at,planned_departure_at) values(planid,i,portalids[i],now()+i*interval '5 minutes',now()+(i*5+3)*interval '1 minute');
  end loop;
  update app_private.route_plan_versions set state='published',published_at=now() where id=planid;
  update app_private.walking_groups set current_plan_version_id=planid where id=groupid;
  for operation in select * from jsonb_array_elements(spec) loop
   problem:=null;tick:=clock_timestamp();
   select * into r from app_private.group_runs where id=runid;
   if r.id is not null then
    select s.sequence,coalesce(s.portal_id,p.portal_id) into n,currentportal from app_private.run_stops s left join app_private.route_plan_stops p on p.id=s.plan_stop_id where s.id=r.current_stop_id;
    token:=tokens[array_position(portalids,currentportal)];
    select jsonb_object_agg(rp.id::text,case when rc.child_id=childids[2] then 'skipped' else 'visited' end) into choices
     from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id where rp.run_id=runid and rp.attendance='present';
    request:=jsonb_build_object('run',runid,'stop',r.current_stop_id,'version',r.version,'token',token,'choices',choices,'key',gen_random_uuid()::text);
   end if;
   begin
    case operation->>'op'
    when 'empty' then perform api.run_start(groupid,'{}'::uuid[],(select version from app_private.walking_groups where id=groupid),gen_random_uuid()::text,'empty');
    when 'start' then
      results:=api.run_start(groupid,case when _scenario='start' then rcids[1:2] else rcids end,(select version from app_private.walking_groups where id=groupid),gen_random_uuid()::text,'start');
      runid:=(results->>'runId')::uuid;
      -- A genuine finale flag on the final isolated stop exercises the same completion transaction.
      insert into app_private.portal_reservations(event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count) values(eventid,portalids[5],groupid,runid,'finale','held',now(),now()+interval '2 hours',3) returning id into fixtureid;
      update app_private.run_stops set stop_kind='finale',portal_id=portalids[5],reservation_id=fixtureid,plan_stop_id=null where run_id=runid and sequence=5;
      insert into app_private.event_route_settings(event_id,final_portal_id) values(eventid,portalids[5]);
    when 'arrive','wrong','stale','repeat' then
      if operation->>'op'='repeat' then request:=previous; end if;
      if operation->>'op' in('arrive','repeat') and exists(select 1 from app_private.run_stops where id=(request->>'stop')::uuid and run_id=runid and stop_kind='finale') then
       perform api.duinpad_finale_confirm('rehearsal-'||replace(eventid::text,'-',''),request->>'token',request->'choices',request->>'key',portalids[5],'qr');
      else
       perform api.run_arrive_and_advance((request->>'run')::uuid,(request->>'stop')::uuid,(request->>'version')::integer-case when operation->>'op'='stale' then 1 else 0 end,
        case when operation->>'op'='wrong' then encode(extensions.gen_random_bytes(32),'hex') else request->>'token' end,request->'choices',request->>'key');
      end if;
      previous:=request;
    when 'close' then perform api.portal_set_operational_state(currentportal,'closed',(select version from app_private.portals where id=currentportal),'Geïsoleerde generale');
    when 'systemskip' then perform api.run_system_skip(runid,r.current_stop_id,r.version,'Gesloten oefenpoort',gen_random_uuid()::text,'system-skip');
    when 'skipall' then perform api.run_bulk_skip_pending(runid,r.current_stop_id,r.version,'Met oefenouder bevestigd',gen_random_uuid()::text,'skip-all');
    when 'complete' then perform api.run_complete_stop(runid,r.current_stop_id,r.version,true,gen_random_uuid()::text,'manual-complete');
    when 'scan' then perform api.run_scan(runid,r.current_stop_id,r.version,token,'qr');
    when 'departone','departall' then
      select array_agg(rp.id order by rp.id) into leavingids from app_private.run_participants rp join app_private.registration_children rc on rc.id=rp.registration_child_id where rp.run_id=runid and rp.attendance='present' and (operation->>'op'='departall' or rc.child_id=childids[2]);
      perform api.run_end_early(runid,r.version,leavingids,'Eigen oefengezin sluit af',gen_random_uuid()::text);
      -- Restore the immutable child order used by the measurement projection.
      select array_agg(rc.child_id order by array_position(rcids,rc.id)) into childids from app_private.registration_children rc where rc.id=any(rcids);
    when 'offline' then null; -- Simulated transport omission: deliberately issue no SQL command.
    when 'snapshot' then null;
    else raise exception 'INVALID_SCENARIO';
    end case;
   exception when others then problem:=SQLERRM;
   end;
   select * into r from app_private.group_runs where id=runid;
   select count(*) into actualhistory from app_private.run_stops where run_id=runid and state='completed';
   select coalesce(sequence,0) into actualseq from app_private.run_stops where id=r.current_stop_id;actualseq:=coalesce(actualseq,0);
   actualstatus:=coalesce(r.status::text,'before');
   select jsonb_agg((select count(*) from app_private.poortenboek_passport_seals seal where seal.event_id=eventid and seal.child_id=rc.child_id) order by array_position(rcids,rc.id)) into sealcounts from app_private.registration_children rc where rc.id=any(rcids);
   ok:=problem is not distinct from operation->>'error' and actualhistory=(operation->>'history')::integer and actualseq=(operation->>'sequence')::integer and actualstatus=operation->>'status' and sealcounts=operation->'seals';
   if _scenario='finale' and actualstatus='completed' then
    ok:=ok and (select count(*)=3 from app_private.poortenboek_passport_seals where event_id=eventid and finale)
     and (select count(*)=1 from app_private.duinpad_finale_receipts where event_id=eventid and run_id=runid)
     and (select count(*)=1 and bool_and(evening_ends_at=first_finale_scan_at+interval '2 hours') from app_private.duinpad_evenings where event_id=eventid and run_id=runid);
   end if;
   view:=jsonb_build_object('connected',operation->>'op'<>'offline','parent',jsonb_build_object('status',actualstatus,'stop',case when actualseq=0 then 'Geen actieve bestemming' else 'Oefenpoort '||actualseq end,'sequence',actualseq,'version',coalesce(r.version,0),'arrived',actualhistory>0,'endedEarly',r.stopped_reason='all_participants_departed'),
    'gate',jsonb_build_object('name','Geïsoleerde oefenpoort','code','LAB','status',coalesce((select operation_status from app_private.portals where id=currentportal),'open'),'scanned',exists(select 1 from app_private.scan_evidence where run_stop_id=r.current_stop_id)),
    'children',(select jsonb_agg(jsonb_build_object('id',rc.id,'name',c.first_name,'attendance',coalesce(rp.attendance::text,'absent'),'choice','Eigen keuze','seals',(select count(*) from app_private.poortenboek_passport_seals where event_id=eventid and child_id=c.id),'finaleSeals',(select count(*) from app_private.poortenboek_passport_seals where event_id=eventid and child_id=c.id and finale)) order by array_position(rcids,rc.id)) from app_private.registration_children rc join app_private.children c on c.id=rc.child_id left join app_private.run_participants rp on rp.registration_child_id=rc.id and rp.run_id=runid where rc.id=any(rcids)),
    'history',coalesce((select jsonb_agg(jsonb_build_object('sequence',sequence,'name','Oefenpoort '||sequence,'outcome',outcome,'arrived',outcome<>'system_skipped') order by sequence) from app_private.run_stops where run_id=runid and state='completed'),'[]'::jsonb));
   report:=report||jsonb_build_array(jsonb_build_object('title',operation->>'title','expectation',(operation-'op'-'title')::text,'actual',jsonb_build_object('error',problem,'history',actualhistory,'sequence',actualseq,'status',actualstatus,'seals',sealcounts)::text,'passed',coalesce(ok,false),'at',clock_timestamp(),'durationMs',round(extract(epoch from clock_timestamp()-tick)*1000),'command',operation->>'op','view',view));
  end loop;
  raise exception using errcode='P7711',message='ROLLBACK_ISOLATED_REHEARSAL';
 exception when sqlstate 'P7711' then null;
 end;
 return jsonb_build_object('scenarioId',_scenario,'title',_scenario,'startedAt',started,'endedAt',clock_timestamp(),'passed',not exists(select 1 from jsonb_array_elements(report) item where not (item->>'passed')::boolean),'steps',report,'environment','Isolated SQL transaction; fixtures rolled back; external transport is not measured');
end $$;
revoke all on function api.redesign_rehearsal(text,text) from public,anon;
grant execute on function api.redesign_rehearsal(text,text) to authenticated;
