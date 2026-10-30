begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);

-- New manual records keep immutable identities and have no resident application.
insert into app_private.portals(id,event_id,world_id,name,description,intensity,
 record_source,system_number,system_code,approval_status,lifecycle_status,operation_status,
 contact_name,contact_phone,contact_email)
select '12000000-0000-0000-0000-000000000038',event_id,world_id,'Handmatige testpoort 38',description,intensity,
 'manual',38,'P-38','approved','active','open','Zoë van den Berg','0612345678','manual-38@example.invalid'
from app_private.portals where id='12000000-0000-0000-0000-000000000001';
insert into app_private.portals(id,event_id,world_id,name,description,intensity,
 record_source,system_number,system_code,approval_status,lifecycle_status,operation_status,
 contact_name,contact_phone,contact_email)
select '12000000-0000-0000-0000-000000000044',event_id,world_id,'Handmatige testpoort 44',description,intensity,
 'manual',44,'P-44','approved','approved','scheduled','Daniël de la Cruz','0687654321','manual-44@example.invalid'
from app_private.portals where id='12000000-0000-0000-0000-000000000002';
insert into app_private.portal_private_locations(portal_id,street,house_number,postal_code,city,latitude,longitude,verified_at,verified_by)
select new.id,l.street,l.house_number,l.postal_code,l.city,l.latitude,l.longitude,l.verified_at,l.verified_by
from app_private.portal_private_locations l cross join (values
 ('12000000-0000-0000-0000-000000000038'::uuid),('12000000-0000-0000-0000-000000000044'::uuid)) new(id)
where l.portal_id='12000000-0000-0000-0000-000000000001';
insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,buffer_minutes,max_concurrent_groups,max_children_per_visit)
select new.id,w.opens_at,w.closes_at,w.visit_minutes,w.buffer_minutes,w.max_concurrent_groups,w.max_children_per_visit
from app_private.portal_windows w cross join (values
 ('12000000-0000-0000-0000-000000000038'::uuid),('12000000-0000-0000-0000-000000000044'::uuid)) new(id)
where w.portal_id='12000000-0000-0000-0000-000000000001';
update app_private.event_route_settings set final_portal_id='12000000-0000-0000-0000-000000000038'
 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026');
select throws_ok($$update app_private.event_route_settings set final_portal_id='12000000-0000-0000-0000-000000000044'
 where event_id=(select id from app_private.events where slug='duindorp-halloween-2026')$$,
 '23514','P38_ONLY_FINAL_PORTAL','another manual house cannot replace the event P-38 finale');
create temp table visibility_before as select
 (select jsonb_agg(to_jsonb(p) order by id) from app_private.portals p) portals,
 (select jsonb_agg(to_jsonb(w) order by id) from app_private.portal_windows w) windows,
 (select count(*) from app_private.email_outbox) mails,
 (select count(*) from app_private.portal_owners) owners,
 app_private.admin_portal_management_snapshot_before_manual_active('duindorp-halloween-2026')-'activePortals' other_sections;
create temp table visibility_snapshot as select api.admin_portal_management_snapshot('duindorp-halloween-2026') data;
create function pg_temp.listed(_code text) returns jsonb language sql as $$
 select p from visibility_snapshot s cross join lateral jsonb_array_elements(s.data->'activePortals') p where p->>'systemCode'=_code
$$;
select is((select count(*) from visibility_snapshot s cross join lateral jsonb_array_elements(s.data->'activePortals') p where p->>'systemCode'='P-38'),1::bigint,'P-38 appears exactly once without an application');
select is((select count(*) from visibility_snapshot s cross join lateral jsonb_array_elements(s.data->'activePortals') p where p->>'systemCode'='P-44'),1::bigint,'approved P-44 appears exactly once while preparing');
select is(pg_temp.listed('P-38')->'applicationId','null'::jsonb,'manual portal keeps its absent application');
select is(pg_temp.listed('P-38')->>'contactName','Zoë van den Berg','manual contact name preserves accents and particles');
select is(pg_temp.listed('P-44')->>'contactName','Daniël de la Cruz','each manual portal uses its own contact');
select is(pg_temp.listed('P-38')->>'phone','0612345678','manual contact phone is projected');
select is(pg_temp.listed('P-44')->>'email','manual-44@example.invalid','manual contact email is projected');
select is(pg_temp.listed('P-38')->>'operationStatus','open','open operational status is preserved');
select is(pg_temp.listed('P-44')->>'operationStatus','scheduled','preparation is not silently changed to open');
select is(pg_temp.listed('P-38')->>'isFinal','true','the manual P-38 remains the actual finale');
select is(pg_temp.listed('P-44')->>'isFinal','false','a preparing manual ordinary house is not presented as a second finale');
select is((pg_temp.listed('P-38')->>'activeReservations')::bigint,(select count(*) from app_private.portal_reservations where portal_id='12000000-0000-0000-0000-000000000038' and status in ('held','active')),'reservation counts remain authoritative');
select is((pg_temp.listed('P-38')->>'expectedChildren')::bigint,(select coalesce(sum(child_count),0) from app_private.portal_reservations where portal_id='12000000-0000-0000-0000-000000000038' and status in ('held','active')),'expected children retain reservation totals');
select is((select data-'activePortals' from visibility_snapshot),(select other_sections from visibility_before),'registration, concepts, capabilities and other sections are preserved');
select is((select jsonb_agg(to_jsonb(p) order by id) from app_private.portals p),(select portals from visibility_before),'reading does not alter portal statuses or relationships');
select is((select jsonb_agg(to_jsonb(w) order by id) from app_private.portal_windows w),(select windows from visibility_before),'reading does not alter availability');
select is((select count(*) from app_private.email_outbox),(select mails from visibility_before),'reading queues no instructions or other mail');
select is((select count(*) from app_private.portal_owners),(select owners from visibility_before),'reading grants no membership');
select is((select lifecycle_status from app_private.portals where system_code='P-44'),'approved','listing does not activate the approved portal');
select ok(exists(select 1 from jsonb_array_elements((select data->'activePortals' from visibility_snapshot)) p where p->>'applicationId' is not null),'resident application portals remain visible');

update app_private.portals set lifecycle_status='concept' where system_code='P-44';
select ok(not exists(select 1 from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026')->'activePortals') p where p->>'systemCode'='P-44'),'a concept does not appear as an approved operational record');
update app_private.portals set lifecycle_status='archived' where system_code='P-44';
select ok(not exists(select 1 from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026')->'activePortals') p where p->>'systemCode'='P-44'),'an archive stays excluded even with an old approved flag');
update app_private.portals set lifecycle_status='approved',approval_status='submitted' where system_code='P-44';
select ok(not exists(select 1 from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026')->'activePortals') p where p->>'systemCode'='P-44'),'unreviewed records stay excluded');
update app_private.portals set approval_status='rejected' where system_code='P-44';
select ok(not exists(select 1 from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026')->'activePortals') p where p->>'systemCode'='P-44'),'rejected records stay excluded');
update app_private.portals set approval_status='approved' where system_code='P-44';
select ok(exists(select 1 from jsonb_array_elements(api.admin_portal_management_snapshot('duindorp-halloween-2026')->'activePortals') p where p->>'systemCode'='P-44'),'a fresh snapshot reflects the current eligible state');
select ok(not has_function_privilege('anon','api.admin_portal_management_snapshot(text)','execute'),'anonymous callers cannot read contacts');
select ok(not has_function_privilege('authenticated','app_private.admin_portal_management_snapshot_before_manual_active(text)','execute'),'the underlying projection remains private');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select throws_ok($$select api.admin_portal_management_snapshot('duindorp-halloween-2026')$$,'42501','NOT_AUTHORIZED','ordinary participants cannot inspect portal contacts');
select * from finish();
rollback;
