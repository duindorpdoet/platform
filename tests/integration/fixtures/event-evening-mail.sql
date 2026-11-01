-- Synthetic committed fixture in the dedicated offline mail integration clone.
-- Never run against an application/staging/production database.
begin;
do $$begin
 if current_database()<>'portal_impact_mail_integration'or not exists(select 1 from app_private.events where slug='duindorp-halloween-2026'and settings->>'fixture'='true')or exists(select 1 from app_private.event_closures)then raise exception 'ISOLATED_FRESH_EVENT_EVENING_MAIL_FIXTURE_REQUIRED';end if;
end $$;
-- Limit this isolated seeded scenario to two families and two houses.
-- Treat exactly these synthetic gates as operational participants in this test.
update app_private.portal_flags set value=false where flag_key='fixture'and portal_id in('12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000002');
update app_private.registrations set status='cancelled';
update app_private.portals set approval_status='draft',lifecycle_status='archived'where id not in('12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000002');
update app_private.events set phase='live'where slug='duindorp-halloween-2026';
update app_private.event_route_settings set final_portal_id='12000000-0000-0000-0000-000000000002'where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)values('f6100000-0000-4000-8000-000000000001','evening-family@example.invalid',now(),'{}','{}');
insert into app_private.households(id,label,primary_contact_user_id)values('f6200000-0000-4000-8000-000000000001','Mail integration synthetic family','f6100000-0000-4000-8000-000000000001');
insert into app_private.household_members(household_id,user_id,relation_role)values('f6200000-0000-4000-8000-000000000001','f6100000-0000-4000-8000-000000000001','owner');
insert into app_private.registrations(id,event_id,household_id,status,reference)select 'f6300000-0000-4000-8000-000000000001',id,'f6200000-0000-4000-8000-000000000001','submitted','EVENT-EVENING-MAIL-LOCAL'from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.children(id,household_id,first_name,age_at_event)values('f6400000-0000-4000-8000-000000000001','f6200000-0000-4000-8000-000000000001','Synthetic child',8);
insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents)select id,'f6300000-0000-4000-8000-000000000001','f6400000-0000-4000-8000-000000000001',0 from app_private.events where slug='duindorp-halloween-2026';
-- A second eligible family exercises standard reactions separately. Their team
-- membership grants room access, never owner mail entitlement.
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)values('f6100000-0000-4000-8000-000000000002','other-evening-family@example.invalid',now(),'{}','{}');
insert into app_private.households(id,label,primary_contact_user_id)values('f6200000-0000-4000-8000-000000000002','Other integration synthetic family','f6100000-0000-4000-8000-000000000002');
insert into app_private.household_members(household_id,user_id,relation_role)values('f6200000-0000-4000-8000-000000000002','f6100000-0000-4000-8000-000000000002','owner');
insert into app_private.registrations(id,event_id,household_id,status,reference)select 'f6300000-0000-4000-8000-000000000002',id,'f6200000-0000-4000-8000-000000000002','submitted','EVENT-EVENING-OTHER-LOCAL'from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.children(id,household_id,first_name,age_at_event)values('f6400000-0000-4000-8000-000000000002','f6200000-0000-4000-8000-000000000002','Other synthetic child',8);
insert into app_private.registration_children(event_id,registration_id,child_id,unit_price_cents)select id,'f6300000-0000-4000-8000-000000000002','f6400000-0000-4000-8000-000000000002',0 from app_private.events where slug='duindorp-halloween-2026';
insert into app_private.portal_owners(portal_id,user_id,role)values('12000000-0000-0000-0000-000000000001','f6100000-0000-4000-8000-000000000002','crew');
-- Suppress unrelated seed-generated fixture jobs, never any live outbox.
update app_private.email_outbox set status='suppressed'where status in('pending','deferred');
commit;
