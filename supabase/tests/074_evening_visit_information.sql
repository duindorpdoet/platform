begin;
\ir fixtures/legacy-start-available.inc
create extension if not exists pgtap with schema extensions;
select no_plan();
select is(app_private.portal_visit_information_projection('12000000-0000-0000-0000-000000000002')->'warnings','null'::jsonb,'old false defaults never become a parent-facing no-effects declaration');
insert into app_private.portal_flags(portal_id,flag_key,value) values('12000000-0000-0000-0000-000000000002','smoke',true);
select is(app_private.portal_visit_information_projection('12000000-0000-0000-0000-000000000002')#>>'{warnings,smoke}','true','actual positive legacy information remains visible');
select ok(not(app_private.portal_visit_information_projection('12000000-0000-0000-0000-000000000002')->'warnings' ? 'flashes'),'unreported legacy fields remain unknown');
create temp table original_credentials as select id,md5(to_jsonb(c)::text) hash from app_private.portal_credentials c;
create temp table original_children as select id,md5(to_jsonb(c)::text) hash from app_private.registration_children c;
create temp table info_fixture(info jsonb,portal_version integer,revision integer,draft jsonb,application_id uuid,application_version integer,new_application uuid,new_portal uuid,original_latitude numeric,original_longitude numeric);
insert into info_fixture(info) values('{"warningDisclosure":"none","warnings":{"smoke":false,"flashes":false,"sound":false,"actors":false,"allergens":false},"warningNotes":"","accessibility":"step_free","accessibilityNotes":"Brede ingang aan de voorkant"}');
update info_fixture set original_latitude=(select coordinate[1]::numeric from app_private.walking_nodes where portal_id='12000000-0000-0000-0000-000000000001' limit 1),original_longitude=(select coordinate[0]::numeric from app_private.walking_nodes where portal_id='12000000-0000-0000-0000-000000000001' limit 1);
grant all on info_fixture to authenticated;
create function pg_temp.admin_payload(pid uuid) returns jsonb language sql security definer set search_path='' as $$
 select item||jsonb_build_object('systemNumber',p.system_number,'contactPhone',item->'phone','contactEmail',item->'email') from jsonb_array_elements(api.admin_portal_editor_snapshot('duindorp-halloween-2026')->'portals') item
 join app_private.portals p on p.id=(item->>'id')::uuid where p.id=pid
$$;
create function pg_temp.current_info() returns jsonb language sql as $$select api.portal_visit_information('12000000-0000-0000-0000-000000000001')$$;
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select is(pg_temp.current_info()#>>'{information,warningDisclosure}','unknown','legacy false flags remain unknown');
update info_fixture set portal_version=(pg_temp.current_info()->>'version')::integer;
select lives_ok($$select api.portal_visit_information_save('12000000-0000-0000-0000-000000000001',portal_version,info) from info_fixture$$,'actual managing owner saves an explicit declaration');
select is(pg_temp.current_info()#>>'{information,warningDisclosure}','none','explicit none is stored distinctly');
select is(pg_temp.current_info()#>>'{information,accessibilityNotes}','Brede ingang aan de voorkant','practical accessibility notes survive');
select throws_ok($$select api.portal_visit_information_save('12000000-0000-0000-0000-000000000001',portal_version,info) from info_fixture$$,'40001','STALE_VERSION','unknown response retry cannot overwrite a newer portal version');
select throws_ok($$select api.portal_visit_information_save('12000000-0000-0000-0000-000000000001',(pg_temp.current_info()->>'version')::integer,info||'{"actor":"forged"}') from info_fixture$$,'22023','INVALID_VISIT_INFORMATION','client cannot inject actor or unrestricted fields');
select throws_ok($$select api.portal_visit_information_save('12000000-0000-0000-0000-000000000001',(pg_temp.current_info()->>'version')::integer,jsonb_set(info,'{warnings,smoke}','"yes"')) from info_fixture$$,'22023','INVALID_VISIT_INFORMATION','warning values must be actual booleans');
select throws_ok($$select api.portal_visit_information_save('12000000-0000-0000-0000-000000000001',(pg_temp.current_info()->>'version')::integer,info||jsonb_build_object('warningNotes',repeat('x',501))) from info_fixture$$,'22023','INVALID_VISIT_INFORMATION','server enforces note size');
set local role postgres;
update app_private.portal_owners set access_level='read' where portal_id='12000000-0000-0000-0000-000000000001' and user_id=auth.uid();
set local role authenticated;
select lives_ok($$select pg_temp.current_info()$$,'read-only own team member may read own house information');
select throws_ok($$select api.portal_visit_information_save('12000000-0000-0000-0000-000000000001',(pg_temp.current_info()->>'version')::integer,info) from info_fixture$$,'42501','NOT_AUTHORIZED','read-only team cannot change practical information');
set local role postgres;
update app_private.portal_owners set access_level='manage' where portal_id='12000000-0000-0000-0000-000000000001' and user_id=auth.uid();
-- Force this seed owner's first portal to be the latest own application.
update app_private.portal_applications set created_at=clock_timestamp()+interval '1 second' where id='11000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select lives_ok($$select api.admin_manual_portal_save('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001',pg_temp.admin_payload('12000000-0000-0000-0000-000000000001')-'visitInformation',(pg_temp.current_info()->>'version')::integer,'Oude beheerclient wijzigt alleen de naam')$$,'old organization payload preserves independently stored information');
select is(pg_temp.current_info()#>>'{information,warningDisclosure}','none','missing field cannot erase explicit none');
select throws_ok($$select api.admin_manual_portal_save('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001',pg_temp.admin_payload('12000000-0000-0000-0000-000000000001')||jsonb_build_object('name','Mag niet worden opgeslagen','visitInformation','{"invalid":true}'::jsonb),(pg_temp.current_info()->>'version')::integer,'Foute praktische informatie mag geen halve wijziging geven')$$,'22023','INVALID_VISIT_INFORMATION','invalid information rejects the whole organization mutation');
select set_config('request.jwt.claims','{"sub":"e0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update info_fixture set draft=api.portal_snapshot('duindorp-halloween-2026')#>'{application,draft}',application_id=(api.portal_snapshot('duindorp-halloween-2026')#>>'{application,id}')::uuid,application_version=(api.portal_snapshot('duindorp-halloween-2026')#>>'{application,version}')::integer;
select is((select draft->>'accessibility' from info_fixture),'step_free','intake snapshot supplies an enum separately from free notes');
select is((select draft->>'visitInformationRevision' from info_fixture),'1','intake snapshot carries the actual information revision');
select lives_ok($$select api.portal_visit_information_save('12000000-0000-0000-0000-000000000001',(pg_temp.current_info()->>'version')::integer,info||'{"warningDisclosure":"listed","warnings":{"smoke":true,"flashes":false,"sound":true,"actors":false,"allergens":false},"warningNotes":"Rook en geluid bij de ingang"}') from info_fixture$$,'owner can update live warnings independently');
select throws_ok($$select api.portal_application_save('duindorp-halloween-2026',draft,application_version) from info_fixture$$,'40001','STALE_VISIT_INFORMATION','old intake form cannot overwrite newer live warnings');
update info_fixture set draft=api.portal_snapshot('duindorp-halloween-2026')#>'{application,draft}',application_version=(api.portal_snapshot('duindorp-halloween-2026')#>>'{application,version}')::integer;
select lives_ok($$select api.portal_application_save('duindorp-halloween-2026',draft||jsonb_build_object('warningNotes','Actuele verklaring via de eigen aanvraag'),application_version) from info_fixture$$,'fresh own intake saves practical information atomically');
select is(pg_temp.current_info()#>>'{information,warningNotes}','Actuele verklaring via de eigen aanvraag','intake and own editor use the same live value');
select is((api.portal_snapshot('duindorp-halloween-2026')#>>'{application,draft,visitInformationRevision}')::integer,3,'new intake revision is available for the next edit');
-- Legacy application edits and subsequent approval must preserve newer live data.
update info_fixture set draft=(api.portal_snapshot('duindorp-halloween-2026')#>'{application,draft}')-'warningDisclosure'-'visitInformationRevision',application_version=(api.portal_snapshot('duindorp-halloween-2026')#>>'{application,version}')::integer;
select lives_ok($$select api.portal_application_save('duindorp-halloween-2026',draft||'{"address":{"street":"Fictief pad","houseNumber":"1","postalCode":"2583AA"},"warnings":{"smoke":false,"flashes":false,"sound":false,"actors":false,"allergens":false}}',application_version) from info_fixture$$,'legacy intake can update its ordinary application fields');
update info_fixture set application_version=(api.portal_application_submit(application_id,(api.portal_snapshot('duindorp-halloween-2026')#>>'{application,version}')::integer,'visit-info-reapproval-submit','visit-info-reapproval-submit')->>'version')::integer;
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_review_portal_application(application_id,application_version,'approved','anders',(select original_latitude from info_fixture),(select original_longitude from info_fixture),'Oude aanvraag opnieuw beoordelen zonder live informatie te wissen') from info_fixture$$,'reapproval preserves separately edited live information');
select is(pg_temp.current_info()#>>'{information,warnings,smoke}','true','legacy false flags cannot erase canonical smoke warning');
select is(pg_temp.current_info()#>>'{information,warningNotes}','Actuele verklaring via de eigen aanvraag','reapproval retains the latest actual note');
-- Reapproval changed the address. Explicitly restore only this synthetic
-- fixture's known walking verification before releasing a real destination.
set local role postgres;
update app_private.portal_private_locations set marker_latitude=(select original_latitude from info_fixture),marker_longitude=(select original_longitude from info_fixture) where portal_id='12000000-0000-0000-0000-000000000001';
update app_private.portal_private_locations set verified_at=clock_timestamp() where portal_id='12000000-0000-0000-0000-000000000001';
update app_private.walking_nodes set verified_at=clock_timestamp(),verified_by='f0000000-0000-0000-0000-000000000001' where portal_id='12000000-0000-0000-0000-000000000001';
update app_private.walking_edges set approved_at=clock_timestamp(),approved_by='f0000000-0000-0000-0000-000000000001' where from_node_id in(select id from app_private.walking_nodes where portal_id='12000000-0000-0000-0000-000000000001') or to_node_id in(select id from app_private.walking_nodes where portal_id='12000000-0000-0000-0000-000000000001');
set local role authenticated;
set local role postgres;
insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,buffer_minutes,max_concurrent_groups,max_children_per_visit,max_children_total)
 select portal_id,clock_timestamp()-interval '1 hour',clock_timestamp()+interval '6 hours',visit_minutes,buffer_minutes,max_concurrent_groups,max_children_per_visit,max_children_total from app_private.portal_windows where portal_id='12000000-0000-0000-0000-000000000001' order by opens_at limit 1;
set local role authenticated;
-- Parent sees only authorized current stop; direct arbitrary-portal reads remain denied.
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.run_start('23000000-0000-0000-0000-000000000001',array(select (item->>'registrationChildId')::uuid from jsonb_array_elements(api.group_roster('23000000-0000-0000-0000-000000000001')) item),(api.group_snapshot('23000000-0000-0000-0000-000000000001')#>>'{group,version}')::integer,'visit-info-group-start','visit-info-group-start')$$,'real route begins under existing start/attendance rules');
select is(api.group_snapshot('23000000-0000-0000-0000-000000000001')#>>'{run,currentStop,portal,warnings,smoke}','true','released current destination includes actual house warnings');
select is(api.group_snapshot('23000000-0000-0000-0000-000000000001')#>>'{run,currentStop,portal,accessibility}','step_free','released destination includes practical access');
select throws_ok($$select api.portal_visit_information('12000000-0000-0000-0000-000000000002')$$,'42501','NOT_AUTHORIZED','leader cannot look up future house information by portal ID');
select set_config('request.jwt.claims','{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select api.group_snapshot('23000000-0000-0000-0000-000000000004')$$,'42501','NOT_AUTHORIZED','information wrapper retains group authorization');
-- Newly approved explicit declarations initialize once from the real intake.
select set_config('request.jwt.claims','{"sub":"b0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
update info_fixture set new_application=(api.portal_application_save('duindorp-halloween-2026',info||'{"contactName":"Fictieve nieuwe bewoner","phone":"0612345678","address":{"street":"Oefenstraat","houseNumber":"90","postalCode":"2583AA"},"requestedWorldSlug":"anders","visitInformationRevision":0}',null)->>'id')::uuid;
select lives_ok($$select api.portal_application_submit(new_application,1,'visit-info-new-intake-submit','visit-info-new-intake-submit') from info_fixture$$,'real new intake retains its ordinary submit flow');
select set_config('request.jwt.claims','{"sub":"f0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.admin_review_portal_application(new_application,2,'approved','anders',null,null,'Nieuwe bewoner met expliciet opgegeven praktische informatie') from info_fixture$$,'real approval initializes the new house declaration');
set local role postgres;
update info_fixture set new_portal=(select id from app_private.portals where application_id=new_application);
select is((select information->>'warningDisclosure' from app_private.portal_visit_information where portal_id=(select new_portal from info_fixture)),'none','new explicit none is preserved through approval');
select ok(not exists(select 1 from original_credentials o left join app_private.portal_credentials c on c.id=o.id where c.id is null or md5(to_jsonb(c)::text)<>o.hash),'all existing credential IDs/revisions/hashes are preserved');
select ok(not exists(select 1 from original_children o left join app_private.registration_children c on c.id=o.id where c.id is null or md5(to_jsonb(c)::text)<>o.hash),'existing children/registration links are preserved');
select ok(not has_table_privilege('authenticated','app_private.portal_visit_information','select'),'canonical storage is private');
select ok(not has_function_privilege('authenticated','app_private.portal_visit_information_value(uuid)','execute'),'parents cannot bypass projection through private helper');
select ok(not has_function_privilege('anon','api.portal_visit_information(uuid)','execute'),'anonymous users cannot read private portal information');
select * from finish();
rollback;
