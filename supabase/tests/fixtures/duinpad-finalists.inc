-- Synthetic, isolated fixture; callers own a BEGIN/ROLLBACK transaction.
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)
select ('d1000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'duinpad-'||n||'@example.invalid',now(),'{}','{}' from generate_series(1,4)n;
insert into app_private.households(id,label,primary_contact_user_id)
select ('d2000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'Duinpad synthetic '||n,('d1000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,3)n;
insert into app_private.household_members(household_id,user_id,relation_role)
select id,primary_contact_user_id,'owner' from app_private.households where id::text like 'd2000000-%';
-- A second adult in the standalone household keeps an account scan-unit.
insert into app_private.household_members(household_id,user_id,relation_role)
values('d2000000-0000-0000-0000-000000000003','d1000000-0000-0000-0000-000000000004','adult');
insert into app_private.registrations(id,event_id,household_id,status,reference)
select ('d3000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,e.id,('d2000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'submitted','DUINPAD-SIM-'||n from app_private.events e,generate_series(1,3)n where e.slug='duindorp-halloween-2026';
insert into app_private.children(id,household_id,first_name,age_at_event)
select ('d4000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,('d2000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'Oefenkind '||n,8 from generate_series(1,3)n;
insert into app_private.registration_children(id,event_id,registration_id,child_id,unit_price_cents)
select ('d5000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,e.id,('d3000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,('d4000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,0 from app_private.events e,generate_series(1,3)n where e.slug='duindorp-halloween-2026';
insert into app_private.together_parties(id,event_id,public_label,creator_household_id,invite_token_hash,expires_at)
select 'd6000000-0000-0000-0000-000000000001',id,'Synthetic together','d2000000-0000-0000-0000-000000000001',extensions.digest('synthetic-together','sha256'),now()+interval '1 day' from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.together_memberships(party_id,registration_id)
values('d6000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-000000000001'),('d6000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-000000000002');
insert into app_private.walking_groups(id,event_id,code,status,route_mode)
select 'd7000000-0000-0000-0000-000000000001',id,'DUINPAD-SIM','live','dynamic' from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.group_registrations(group_id,registration_id,assignment_revision,published_at)
select 'd7000000-0000-0000-0000-000000000001',id,1,now() from app_private.registrations where id::text like 'd3000000-%';
insert into app_private.group_runs(id,group_id,status,started_at)
values('d8000000-0000-0000-0000-000000000001','d7000000-0000-0000-0000-000000000001','live',now()-interval '30 minutes');
insert into app_private.run_participants(id,run_id,registration_child_id)
select ('d9000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'d8000000-0000-0000-0000-000000000001',('d5000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,3)n;
-- Fresh seed deliberately has no production finale mapping. This is only the
-- synthetic test portal identity supplied by seed.sql.
update app_private.event_route_settings set final_portal_id='12000000-0000-0000-0000-000000000030' where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
update app_private.portals set operation_status='open' where id=(select final_portal_id from app_private.event_route_settings where event_id=(select id from app_private.events where slug='duindorp-halloween-2026'));
insert into app_private.portal_reservations(id,event_id,portal_id,group_id,run_id,kind,status,reserved_from,reserved_until,child_count)
select 'da000000-0000-0000-0000-000000000001',s.event_id,s.final_portal_id,'d7000000-0000-0000-0000-000000000001','d8000000-0000-0000-0000-000000000001','finale','active',now()-interval '1 minute',now()+interval '15 minutes',3 from app_private.event_route_settings s join app_private.events e on e.id=s.event_id where e.slug='duindorp-halloween-2026';
insert into app_private.run_stops(id,run_id,portal_id,reservation_id,stop_kind,sequence,state,opened_at)
select 'db000000-0000-0000-0000-000000000001','d8000000-0000-0000-0000-000000000001',final_portal_id,'da000000-0000-0000-0000-000000000001','finale',1,'active',now()-interval '1 minute' from app_private.event_route_settings where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
update app_private.group_runs set current_stop_id='db000000-0000-0000-0000-000000000001' where id='d8000000-0000-0000-0000-000000000001';
insert into app_private.stop_participant_statuses(run_stop_id,run_participant_id)
select 'db000000-0000-0000-0000-000000000001',id from app_private.run_participants where run_id='d8000000-0000-0000-0000-000000000001';
insert into app_private.portal_credentials(portal_id,token_hash,short_code_hash,version,valid_from)
select final_portal_id,extensions.digest('DUINPAD-SIM-FINALE-TOKEN','sha256'),extensions.digest('DUI-SIM','sha256'),coalesce((select max(c.version)+1 from app_private.portal_credentials c where c.portal_id=s.final_portal_id),1),now()-interval '1 minute' from app_private.event_route_settings s where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
