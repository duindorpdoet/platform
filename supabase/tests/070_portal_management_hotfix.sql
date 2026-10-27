begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
-- Real command payload built from the same snapshot as the organization form.
create function pg_temp.portal_payload(pid uuid) returns jsonb language sql as $$
 select item||jsonb_build_object('systemNumber',p.system_number,'contactPhone',item->'phone','contactEmail',item->'email')
 from jsonb_array_elements(api.admin_portal_editor_snapshot('duindorp-halloween-2026')->'portals') item
 join app_private.portals p on p.id=(item->>'id')::uuid where p.id=pid
$$;
create function pg_temp.registration_for(pid uuid) returns jsonb language sql as $$
 select item from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026')->'registrations') item
 where item->>'portalId'=pid::text
$$;
create temp table portal_test(pid uuid,version integer,payload jsonb,old_application uuid,old_source text);
insert into portal_test select id,version,null,application_id,record_source from app_private.portals
 where id='12000000-0000-0000-0000-000000000002';
update app_private.portal_private_locations set street='Fictieve Lange Straat',house_number='12',addition='B',postal_code='2583AA' where portal_id=(select pid from portal_test);
update app_private.portals set intensity=3,accessibility_notes='Bestaande toegankelijkheid',internal_notes='Bestaande interne notitie' where id=(select pid from portal_test);
update app_private.portal_windows set visit_minutes=9,buffer_minutes=4,max_children_total=79 where portal_id=(select pid from portal_test);
create temp table original_windows as select * from app_private.portal_windows where portal_id=(select pid from portal_test);
update portal_test set payload=pg_temp.portal_payload(pid);
select is((select payload->>'street' from portal_test),'Fictieve Lange Straat','structured street is returned without splitting formatted address');
select is((select payload->>'houseNumber' from portal_test),'12','house number stays separate from addition');
select is((select payload->>'addition' from portal_test),'B','house number addition is returned');
select is((select payload->>'intensity' from portal_test),'3','existing intensity is loaded');
select is((select payload->>'visitMinutes' from portal_test),'9','existing visit duration is loaded');
select lives_ok($$select api.admin_manual_portal_save('duindorp-halloween-2026',pid,payload||'{"name":"Bijgewerkte bewonerspoort"}',version,'Organisatie past alleen de poortnaam aan') from portal_test$$,'organization can edit a resident portal');
select is((select name from app_private.portals where id=(select pid from portal_test)),'Bijgewerkte bewonerspoort','new portal name is saved');
select is(pg_temp.registration_for((select pid from portal_test))#>>'{draft,portalName}','Bijgewerkte bewonerspoort','registration view reflects managed portal name');
select is(pg_temp.registration_for((select pid from portal_test))#>>'{address,addition}','B','registration view reflects managed address addition');
select is((select application_id from app_private.portals where id=(select pid from portal_test)),(select old_application from portal_test),'original application link survives');
select is((select record_source from app_private.portals where id=(select pid from portal_test)),(select old_source from portal_test),'resident origin survives');
select is((select intensity::integer from app_private.portals where id=(select pid from portal_test)),3,'name edit preserves intensity');
select is((select internal_notes from app_private.portals where id=(select pid from portal_test)),'Bestaande interne notitie','name edit preserves internal notes');
select results_eq($$select * from app_private.portal_windows where portal_id=(select pid from portal_test)$$,$$select * from original_windows$$,'unrelated edit preserves full original window rows and limits');
select is((select addition from app_private.portal_private_locations where portal_id=(select pid from portal_test)),'B','name edit preserves address addition');
select throws_ok($$select api.admin_manual_portal_save('duindorp-halloween-2026',pid,payload,version,'Een verouderd formulier mag niet overschrijven') from portal_test$$,'P0001','STALE_VERSION','stale edit is rejected without an API retry loop');
update portal_test set version=(select p.version from app_private.portals p where p.id=pid),payload=pg_temp.portal_payload(pid);
select lives_ok($$select api.admin_manual_portal_save('duindorp-halloween-2026',pid,payload||'{"visitMinutes":10,"maxChildren":18}',version,'Organisatie wijzigt expliciet de planning') from portal_test$$,'single window planning can be edited');
select is((select visit_minutes from app_private.portal_windows where portal_id=(select pid from portal_test)),10,'visit duration changed');
select is((select id from app_private.portal_windows where portal_id=(select pid from portal_test)),(select id from original_windows),'window identity is retained');
select is((select max_children_total from app_private.portal_windows where portal_id=(select pid from portal_test)),79,'unexposed total capacity is retained');
insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,buffer_minutes,max_concurrent_groups,max_children_per_visit)
 select portal_id,opens_at+interval '1 day',closes_at+interval '1 day',visit_minutes,buffer_minutes,max_concurrent_groups,max_children_per_visit from original_windows;
update portal_test set version=(select p.version from app_private.portals p where p.id=pid),payload=pg_temp.portal_payload(pid);
select lives_ok($$select api.admin_manual_portal_save('duindorp-halloween-2026',pid,payload||'{"contactName":"Aangepast contact"}',version,'Contactpersoon aanpassen behoudt alle tijdvakken') from portal_test$$,'multi-window portal allows unrelated edits');
select is((select count(*)::integer from app_private.portal_windows where portal_id=(select pid from portal_test)),2,'multiple windows are preserved');
update portal_test set version=(select p.version from app_private.portals p where p.id=pid),payload=pg_temp.portal_payload(pid);
select throws_ok($$select api.admin_manual_portal_save('duindorp-halloween-2026',pid,payload||'{"visitMinutes":11}',version,'Meerdere tijdvakken mogen niet samengevoegd worden') from portal_test$$,'23514','MULTIPLE_AVAILABILITY_WINDOWS','multiple windows cannot silently collapse');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.admin_manual_portal_save('duindorp-halloween-2026',pid,payload,version,'Niet bevoegd om poortgegevens aan te passen') from portal_test$$,'42501','NOT_AUTHORIZED','participant cannot edit portals');
select throws_ok($$select api.admin_manual_portal_remove(pid,version,'Niet bevoegd om een poort te verwijderen') from portal_test$$,'42501','NOT_AUTHORIZED','participant cannot remove portals');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update app_private.event_route_settings set final_portal_id='12000000-0000-0000-0000-000000000030';
select throws_ok($$select api.admin_manual_portal_remove('12000000-0000-0000-0000-000000000030',(select version from app_private.portals where id='12000000-0000-0000-0000-000000000030'),'Finale blijft behouden zolang die is ingesteld')$$,'23514','CHOOSE_REPLACEMENT_FINAL_PORTAL_FIRST','configured finale cannot be removed');
select throws_ok($$select api.admin_manual_portal_remove(pid,version-1,'Een verouderd formulier mag niet verwijderen') from portal_test$$,'40001','STALE_VERSION','stale removal is rejected');
select lives_ok($$select api.admin_manual_portal_remove(pid,version,'Bewonerspoort verwijderen uit actief beheer') from portal_test$$,'resident portal can be removed from active management');
select is((select lifecycle_status from app_private.portals where id=(select pid from portal_test)),'archived','resident portal is archived to retain historical relations');
select is(pg_temp.registration_for((select pid from portal_test))->>'status','closed','archived registration remains in history with closed status');
select is((select operation_status::text from app_private.portals where id=(select pid from portal_test)),'closed','archived portal is closed');
select is((select application_id from app_private.portals where id=(select pid from portal_test)),(select old_application from portal_test),'removal retains application and account relation');
select ok(not exists(select 1 from jsonb_array_elements(api.admin_portal_editor_snapshot('duindorp-halloween-2026')->'portals') item where item->>'id'=(select pid::text from portal_test)),'removed portal disappears from management snapshot');
create temp table unused_concept as select (api.admin_manual_portal_save('duindorp-halloween-2026',null,jsonb_build_object('name','Ongebruikt handmatig concept','worldSlug',(select slug from app_private.worlds order by sort_order limit 1)),null,'Nieuw ongebruikt concept voor de verwijderproef')->>'id')::uuid id;
select is((api.admin_manual_portal_remove((select id from unused_concept),1,'Verwijder dit ongebruikte handmatige concept')->>'deleted')::boolean,true,'unused manual concept is permanently deleted');
select ok(not exists(select 1 from app_private.portals where id=(select id from unused_concept)),'unused concept record no longer exists');
-- Held visits must be resolved before a portal can disappear from the active route.
insert into app_private.portal_reservations(event_id,portal_id,group_id,kind,status,reserved_from,reserved_until,child_count)
 select event_id,'12000000-0000-0000-0000-000000000003',id,'ordinary','held',statement_timestamp(),statement_timestamp()+interval '10 minutes',1
 from app_private.walking_groups where id='23000000-0000-0000-0000-000000000001';
select throws_ok($$select api.admin_manual_portal_remove('12000000-0000-0000-0000-000000000003',(select version from app_private.portals where id='12000000-0000-0000-0000-000000000003'),'Poort met een gereserveerd bezoek verwijderen')$$,'23514','RESOLVE_ACTIVE_VISITS_FIRST','held visits block removal');
select ok(not has_function_privilege('anon','api.admin_portal_editor_snapshot(text)','execute'),'anonymous clients cannot read portal editor details');
insert into app_private.event_capabilities(event_id,user_id,capability,granted_by)
 select id,'a0000000-0000-0000-0000-000000000001','portals_manage','f0000000-0000-0000-0000-000000000001' from app_private.events where slug='duindorp-halloween-2026';
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_portal_editor_snapshot('duindorp-halloween-2026')$$,'portal-only manager can load editor without group-planning capability');
select ok(not (api.admin_portal_editor_snapshot('duindorp-halloween-2026') ? 'groups'),'portal editor does not disclose group-planning data');
select * from finish();
rollback;
