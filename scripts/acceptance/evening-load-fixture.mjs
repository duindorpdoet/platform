import { randomUUID, randomBytes, createHash } from 'node:crypto';
// Owned synthetic records in a separate event. Never clone, reset or alter the
// site's real event; immutable test publications remain as labeled test history.
export function makeEveningLoadFixture({ families = 200, portals = 30, admins = 4, observers = 20 } = {}) {
    for (const [name, n] of Object.entries({ families, portals, admins, observers }))
        if (!Number.isSafeInteger(n) || n < 1 || n > 500)
            throw new Error(`INVALID_LOAD_COUNT_${name}`);
    if (portals < 3)
        throw new Error('LOAD_NEEDS_THREE_PORTALS');
    const id = () => randomUUID(), eventId = id(), slug = `evening-load-${Date.now()}-${randomBytes(3).toString('hex')}`;
    const actors = [], groups = Array.from({ length: Math.ceil(families / 8) }, () => ({ id: id() }));
    for (let i = 0; i < families; i++)
        actors.push({ id: id(), kind: 'family', groupId: groups[Math.floor(i / 8)].id, householdId: id(), registrationId: id(), childId: id(), registrationChildId: id() });
    if (groups.length > portals - 1)
        throw new Error('LOAD_NEEDS_ONE_ORDINARY_HOUSE_PER_CONCURRENT_GROUP');
    const houses = Array.from({ length: portals }, (_, i) => ({ id: id(), applicationId: id(), nodeId: id(), token: randomBytes(24).toString('hex'), index: i + 1 }));
    for (const house of houses) {
        const owner = { id: id(), kind: 'portal', portalId: house.id };
        actors.push(owner);
        house.ownerId = owner.id;
    }
    for (let i = 0; i < admins + observers; i++)
        actors.push({ id: id(), kind: i < admins ? 'admin' : 'observer' });
    for (const actor of actors) {
        actor.email = `${slug}-${actor.kind}-${actor.id}@example.invalid`;
        actor.password = randomBytes(32).toString('base64url');
    }
    return { eventId, slug, worldId: id(), startId: id(), startNodeId: id(), actors, groups, houses, counts: { families, portals, admins, observers } };
}
const quote = value => "'" + String(value).replaceAll("'", "''") + "'";
export function eveningLoadFixtureSql(f) {
    const safe = { ...f, actors: f.actors.map(({ id, kind, groupId, householdId, registrationId, childId, registrationChildId }) => ({ id, kind, groupId, householdId, registrationId, childId, registrationChildId })), houses: f.houses.map(({ token, ...house }) => ({ ...house, tokenHash: createHash('sha256').update(token).digest('hex') })) };
    return `begin;
set local statement_timeout='120s';
do $body$
declare f jsonb:=${quote(JSON.stringify(safe))}::jsonb;
 eid uuid:=(f->>'eventId')::uuid; wid uuid:=(f->>'worldId')::uuid; sid uuid:=(f->>'startId')::uuid; nid uuid:=(f->>'startNodeId')::uuid;
 actor uuid:=(select (entry.item->>'id')::uuid from jsonb_array_elements(f->'actors') entry(item) where entry.item->>'kind'='admin' limit 1);
 a jsonb; h jsonb; g jsonb; idx integer; finale uuid:=(f#>>'{houses,-1,id}')::uuid;
begin
 if exists(select 1 from app_private.events where id=eid or slug=f->>'slug') then raise exception 'LOAD_EVENT_ALREADY_EXISTS';end if;
 insert into app_private.events(id,slug,title,local_date,phase,price_cents,settings)
 values(eid,f->>'slug','UITSLUITEND FICTIEVE AVONDBELASTINGPROEF',current_date,'live',0,'{"fixture":true,"eveningLoad":true,"maxGroupSize":20,"termsVersion":"load-v1","privacyVersion":"load-v1"}');
 insert into app_private.worlds(id,event_id,slug,name,sort_order) values(wid,eid,'load','Fictieve testwereld',1);
 for a in select value from jsonb_array_elements(f->'actors') loop
  if a->>'kind' in ('admin','observer') then
   insert into app_private.event_capabilities(event_id,user_id,capability,granted_by)
   select eid,(a->>'id')::uuid,cap,actor from unnest(case when a->>'kind'='admin' then array['event_admin','groups_manage','portals_manage','live_support'] else array['live_support'] end) cap;
  end if;
 end loop;
 for h in select value from jsonb_array_elements(f->'houses') loop
  idx:=(h->>'index')::integer;
  insert into app_private.portal_applications(id,event_id,applicant_user_id,review_status,requested_world_id,private_draft_data,submitted_at,reviewed_by,reviewed_at)
  values((h->>'applicationId')::uuid,eid,(h->>'ownerId')::uuid,'approved',wid,'{"fixture":true}',clock_timestamp(),actor,clock_timestamp());
  insert into app_private.portals(id,event_id,application_id,world_id,name,description,intensity,approval_status,operation_status)
  values((h->>'id')::uuid,eid,(h->>'applicationId')::uuid,wid,'FICTIEVE PROEFPOORT '||idx,'Geen werkelijk bezoekadres',1,'approved','open');
  insert into app_private.portal_private_locations(portal_id,street,house_number,postal_code,city,latitude,longitude,verified_at,verified_by)
  values((h->>'id')::uuid,'GEEN ECHT ADRES',idx::text,'0000AA','Fictieve proef',52.1+idx*.0001,4.27+idx*.0001,clock_timestamp(),actor);
  insert into app_private.portal_owners(portal_id,user_id) values((h->>'id')::uuid,(h->>'ownerId')::uuid);
  insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,buffer_minutes,max_concurrent_groups,max_children_per_visit,max_children_total)
  values((h->>'id')::uuid,clock_timestamp()-interval '1 hour',clock_timestamp()+interval '8 hours',1,0,
   case when (h->>'id')::uuid=finale then jsonb_array_length(f->'groups')+5 else 1 end,
   case when (h->>'id')::uuid=finale then (f#>>'{counts,families}')::integer+10 else 8 end,(f#>>'{counts,families}')::integer*2);
  insert into app_private.portal_credentials(portal_id,token_hash,short_code_hash,version,valid_from,valid_until)
  values((h->>'id')::uuid,decode(h->>'tokenHash','hex'),decode(h->>'tokenHash','hex'),1,clock_timestamp()-interval '1 hour',clock_timestamp()+interval '1 day');
  insert into app_private.walking_nodes(id,event_id,external_id,kind,portal_id,coordinate,verified_at,verified_by)
  values((h->>'nodeId')::uuid,eid,'load-portal-'||idx,'portal',(h->>'id')::uuid,point(4.27+idx*.0001,52.1+idx*.0001),clock_timestamp(),actor);
 end loop;
 insert into app_private.walking_nodes(id,event_id,external_id,kind,coordinate,verified_at,verified_by) values(nid,eid,'load-start','start',point(4.27,52.1),clock_timestamp(),actor);
 insert into app_private.start_points(id,event_id,name,private_address,latitude,longitude,walking_node_id,max_gathering_groups,max_gathering_children,verified_at,verified_by)
 values(sid,eid,'FICTIEF PROEFSTARTPUNT','GEEN ECHT STARTADRES',52.1,4.27,nid,jsonb_array_length(f->'groups')+5,(f#>>'{counts,families}')::integer+10,clock_timestamp(),actor);
 insert into app_private.start_slots(id,event_id,external_id,name,location_name,private_address,latitude,longitude,location_verified_at,starts_at,max_groups,max_children,start_point_id)
 values(sid,eid,'load-start','Fictieve proefstart','Fictieve proef','GEEN ECHT STARTADRES',52.1,4.27,clock_timestamp(),clock_timestamp()-interval '1 minute',jsonb_array_length(f->'groups')+5,(f#>>'{counts,families}')::integer+10,sid);
 for h in select value from jsonb_array_elements(f->'houses') loop
  insert into app_private.walking_edges(event_id,external_id,from_node_id,to_node_id,distance_m,duration_seconds,wheelchair_accessible,approved_at,approved_by)
  values(eid,'load-edge-'||(h->>'index'),nid,(h->>'nodeId')::uuid,25,5,true,clock_timestamp(),actor);
 end loop;
 insert into app_private.event_route_settings(event_id,first_start_at,global_ordinary_stop_at,ordinary_visit_seconds,route_buffer_seconds,final_portal_id,finale_opens_at,finale_last_arrival_at,finale_closes_at,finale_show_seconds,finale_turnover_seconds,finale_max_concurrent_groups,finale_max_concurrent_children,finale_safe_approach,finale_waiting_area,planner_mode)
 values(eid,clock_timestamp()-interval '1 hour',clock_timestamp()+interval '3 hours',60,0,finale,clock_timestamp()-interval '1 hour',clock_timestamp()+interval '5 hours',clock_timestamp()+interval '6 hours',60,120,jsonb_array_length(f->'groups')+5,(f#>>'{counts,families}')::integer+10,'Fictieve gecontroleerde testaanloop','Fictieve veilige proefplek','dynamic');
 for g in select value from jsonb_array_elements(f->'groups') loop
  insert into app_private.walking_groups(id,event_id,code,status,start_slot_id,route_mode,desired_ordinary_visits) values((g->>'id')::uuid,eid,'PROEF-'||(g->>'id'),'ready',sid,'dynamic',2);
 end loop;
 for a in select value from jsonb_array_elements(f->'actors') where value->>'kind'='family' loop
  insert into app_private.households(id,label,primary_contact_user_id,phone) values((a->>'householdId')::uuid,'FICTIEF PROEFGEZIN',(a->>'id')::uuid,'0000000000');
  insert into app_private.household_members(household_id,user_id,relation_role) values((a->>'householdId')::uuid,(a->>'id')::uuid,'owner');
  insert into app_private.registrations(id,event_id,household_id,status,reference,submitted_at,terms_version,terms_accepted_at,privacy_version,price_snapshot_cents)
  values((a->>'registrationId')::uuid,eid,(a->>'householdId')::uuid,'submitted','PROEF-'||(a->>'registrationId'),clock_timestamp(),'load-v1',clock_timestamp(),'load-v1',0);
  insert into app_private.children(id,household_id,first_name,age_at_event) values((a->>'childId')::uuid,(a->>'householdId')::uuid,'Fictief proefkind',10);
  insert into app_private.registration_children(id,event_id,registration_id,child_id,unit_price_cents) values((a->>'registrationChildId')::uuid,eid,(a->>'registrationId')::uuid,(a->>'childId')::uuid,0);
  insert into app_private.payment_requests(registration_id,purpose,amount_cents,reference,status) values((a->>'registrationId')::uuid,'event_registration',0,'PROEF-BETAALD-'||(a->>'registrationId'),'waived');
  insert into app_private.group_registrations(group_id,registration_id,published_at,assignment_revision) values((a->>'groupId')::uuid,(a->>'registrationId')::uuid,clock_timestamp(),1);
 end loop;
 for g in select value from jsonb_array_elements(f->'groups') loop
  insert into app_private.group_leaders(group_id,user_id,active_from,revision,assigned_by)
  select (g->>'id')::uuid,(entry.item->>'id')::uuid,clock_timestamp()-interval '1 hour',1,actor from jsonb_array_elements(f->'actors') entry(item) where entry.item->>'groupId'=g->>'id' limit 1;
  insert into app_private.group_schedule_revisions(group_id,revision,state,start_slot_id,effective_ordinary_stop_at,expected_finale_arrival_at,preference_match,published_at)
  values((g->>'id')::uuid,1,'published',sid,clock_timestamp()+interval '3 hours',clock_timestamp()+interval '4 hours','neutral',clock_timestamp());
  update app_private.walking_groups set current_schedule_revision_id=(select id from app_private.group_schedule_revisions where group_id=(g->>'id')::uuid and revision=1) where id=(g->>'id')::uuid;
 end loop;
end $body$;
commit;`;
}
