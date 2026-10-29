begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select ok(not has_function_privilege('anon','api.portal_print_access(uuid,uuid,text,integer,text,bytea,bytea)','execute'),'anonymous cannot obtain or provision poster secrets');
select ok(not has_function_privilege('authenticated','api.portal_print_access(uuid,uuid,text,integer,text,bytea,bytea)','execute'),'browser roles cannot impersonate the server actor');
select ok(not has_table_privilege('authenticated','app_private.portal_print_material','select'),'encrypted poster storage stays private');
create temp table print_case as select p.id,p.event_id,p.version,
 app_private.joint_route_source_hash(p.event_id)source_hash,
 (select md5(jsonb_agg(to_jsonb(c)order by c.id)::text)from app_private.portal_credentials c where c.portal_id=p.id)legacy_fingerprint,
 null::jsonb material,null::jsonb repeated
from app_private.portals p where p.id='12000000-0000-0000-0000-000000000001';
select is((select count(*)::integer from print_case),1,'the synthetic poster fixture exists');
select throws_ok($$select api.portal_print_access('b0000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000001','ensure',null,repeat('encrypted-fixture',8),extensions.digest('NEW-QR-112','sha256'),extensions.digest('NEW-SHORT-112','sha256'))$$,'42501','NOT_AUTHORIZED','unrelated authenticated parent cannot provision or read house codes');
select lives_ok($$update print_case set material=api.portal_print_access('e0000000-0000-0000-0000-000000000001',id,'ensure',null,repeat('encrypted-fixture',8),extensions.digest('NEW-QR-112','sha256'),extensions.digest('NEW-SHORT-112','sha256'))$$,'owner viewing a legacy code provisions a persistent printable companion');
select is(material->>'legacy','false','the new printable code is recoverable')from print_case;
select is(material->>'canRotate','true','actual managing owner can deliberately rotate')from print_case;
select is((select count(*)::integer from app_private.portal_print_material m join app_private.portal_credentials c on c.id=m.credential_id where c.portal_id=print_case.id),1,'exactly one encrypted print material exists')from print_case;
select is((select md5(jsonb_agg(to_jsonb(c)order by c.id)::text)from app_private.portal_credentials c where c.portal_id=print_case.id and c.id<>(material->>'credentialId')::uuid),legacy_fingerprint,'provisioning preserves previous credential rows byte-for-byte')from print_case;
select is((select version from app_private.portals where id=print_case.id),version,'an ordinary QR view does not change portal version')from print_case;
select is(app_private.joint_route_source_hash(event_id),source_hash,'QR provisioning does not invalidate an accepted route source')from print_case;
select is((select valid_until from app_private.portal_credentials where id=(material->>'credentialId')::uuid),null::timestamptz,'persistent print material has no UI-created expiry')from print_case;
update print_case set repeated=api.portal_print_access('e0000000-0000-0000-0000-000000000001',id,'ensure',null,repeat('discarded-next-candidate',8),extensions.digest('DISCARDED-QR','sha256'),extensions.digest('DISCARDED-SHORT','sha256'));
select is(repeated,material,'reload and tab return reuse exactly the same stored material')from print_case;
select is((select count(*)::integer from app_private.portal_credentials where portal_id=print_case.id),2,'repeated provision creates no duplicate credential')from print_case;
insert into app_private.portal_owners(portal_id,user_id,role,access_level)values('12000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001','viewer','view');
select is(api.portal_print_access('a0000000-0000-0000-0000-000000000001',id,'ensure')->>'ciphertext',material->>'ciphertext','authorized viewer can recover the same existing printable poster')from print_case;
select is(api.portal_print_access('a0000000-0000-0000-0000-000000000001',id,'ensure')->>'canRotate','false','read access never grants rotation capability')from print_case;
select throws_ok($$select api.portal_print_access('a0000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000001','rotate',(select version from print_case),repeat('encrypted-viewer',8),extensions.digest('VIEWER-QR','sha256'),extensions.digest('VIEWER-SHORT','sha256'))$$,'42501','NOT_AUTHORIZED','viewer cannot revoke posters through rotation');
-- An existing journey tests the real QR and manual validation path. No route,
-- reservation or running group is changed by viewing or issuing print material.
insert into app_private.group_runs(id,group_id,status,started_at)
select 'd1120000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000001','live',activated_at-interval '1 minute'
from app_private.joint_route_policy_releases where policy_version='joint-reception-v1';
insert into app_private.run_stops(id,run_id,plan_stop_id,sequence,state,opened_at)
select 'd1120000-0000-0000-0000-000000000002','d1120000-0000-0000-0000-000000000001',stop.id,1,'active',clock_timestamp()
from app_private.walking_groups g join app_private.route_plan_stops stop on stop.plan_version_id=g.current_plan_version_id
where g.id='23000000-0000-0000-0000-000000000001'and stop.portal_id='12000000-0000-0000-0000-000000000001';
update app_private.group_runs set current_stop_id='d1120000-0000-0000-0000-000000000002'where id='d1120000-0000-0000-0000-000000000001';
select set_config('request.jwt.claims','{"sub":"c0000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select lives_ok($$select api.run_scan('d1120000-0000-0000-0000-000000000001','d1120000-0000-0000-0000-000000000002',(select version from app_private.group_runs where id='d1120000-0000-0000-0000-000000000001'),'TEST-PORTAL-01-TOKEN','qr')$$,'previously printed legacy QR remains accepted after provisioning');
select lives_ok($$select api.run_scan('d1120000-0000-0000-0000-000000000001','d1120000-0000-0000-0000-000000000002',(select version from app_private.group_runs where id='d1120000-0000-0000-0000-000000000001'),'test-01','short_code')$$,'previous short code still works case-insensitively');
select lives_ok($$select api.run_scan('d1120000-0000-0000-0000-000000000001','d1120000-0000-0000-0000-000000000002',(select version from app_private.group_runs where id='d1120000-0000-0000-0000-000000000001'),'NEW-QR-112','qr')$$,'the additional persistent QR is accepted by the real scan command');
select lives_ok($$select api.run_scan('d1120000-0000-0000-0000-000000000001','d1120000-0000-0000-0000-000000000002',(select version from app_private.group_runs where id='d1120000-0000-0000-0000-000000000001'),'new-short-112','short_code')$$,'the persistent manual code is also accepted');
select is((select count(*)::integer from app_private.run_stops where run_id='d1120000-0000-0000-0000-000000000001'),1,'scanning or viewing codes never advances the running route');
select ok(not exists(select 1 from app_private.audit_events where action='portal.print_material_created'and minimal_change::text~'NEW-QR|NEW-SHORT|encrypted-fixture|token_hash|ciphertext'),'print provisioning audits contain no code or encrypted material');
select throws_ok($$select api.portal_print_access('e0000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000001','rotate',(select version+10 from print_case),repeat('encrypted-rotation',8),extensions.digest('ROTATED-QR','sha256'),extensions.digest('ROTATED-SHORT','sha256'))$$,'40001','STALE_VERSION','rotation keeps its optimistic version guard');
select lives_ok($$update print_case set repeated=api.portal_print_access('e0000000-0000-0000-0000-000000000001',id,'rotate',version,repeat('encrypted-rotation',8),extensions.digest('ROTATED-QR','sha256'),extensions.digest('ROTATED-SHORT','sha256'))$$,'a deliberately confirmed manager rotation still works');
select is((select count(*)::integer from app_private.portal_credentials where portal_id=print_case.id and revoked_at is null),1,'only explicit rotation revokes earlier posters')from print_case;
select throws_ok($$select api.run_scan('d1120000-0000-0000-0000-000000000001','d1120000-0000-0000-0000-000000000002',(select version from app_private.group_runs where id='d1120000-0000-0000-0000-000000000001'),'NEW-QR-112','qr')$$,'22023','WRONG_PORTAL','the previously active QR is rejected only after explicit rotation');
select *from finish();
rollback;
