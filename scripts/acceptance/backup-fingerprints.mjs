// Temporary synthetic rows only, on an explicitly isolated local test database.
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';
import {fingerprintQuery,compareFingerprints} from '../deploy/redesign-backup.mjs';

const container=process.env.BACKUP_FINGERPRINT_DB_CONTAINER;
if(!/^(duindorp-fingerprint-regression|supabase_db_duindorphalloween|supabase_db_duindorp-account-app)$/.test(container??''))throw new Error('ISOLATED_FINGERPRINT_DATABASE_REQUIRED');
const catalog=[{schema:'pg_temp',name:'backup_fingerprint_fixture',columns:['coordinate','amount','seen_at','label']}];
const fingerprint=()=>`begin;${fingerprintQuery(catalog)};commit;`;
const sql=`
create temporary table backup_fingerprint_fixture(coordinate point,amount double precision,seen_at timestamptz,label text);
insert into backup_fingerprint_fixture values(point(4.123456789012345,52.123456789012345),0.12345678901234567,'2026-10-27T12:34:56.123456Z','synthetic fixture');
set extra_float_digits=0;set timezone='Europe/Amsterdam';set datestyle='German';
select jsonb_build_object('legacy',md5(to_jsonb(row(coordinate))::text)) from backup_fingerprint_fixture;
${fingerprint()}
select jsonb_build_object('settingAfter',current_setting('extra_float_digits'));
set extra_float_digits=1;set timezone='UTC';set datestyle='ISO';
select jsonb_build_object('legacy',md5(to_jsonb(row(coordinate))::text)) from backup_fingerprint_fixture;
${fingerprint()}
select jsonb_build_object('settingAfter',current_setting('extra_float_digits'));
update backup_fingerprint_fixture set coordinate=point(4.123456789012346,52.123456789012345);
${fingerprint()}
delete from backup_fingerprint_fixture;
${fingerprint()}
`;
const output=execFileSync('docker',['exec','-i',container,'psql','-X','-qAt','-U','supabase_admin','-d','postgres','-v','ON_ERROR_STOP=1'],{input:sql,encoding:'utf8',timeout:30000});
const rows=output.trim().split('\n').map(line=>JSON.parse(line));
const legacy=rows.filter(row=>'legacy' in row),settings=rows.filter(row=>'settingAfter' in row).map(row=>row.settingAfter);
const [source,restored,changed,missing]=rows.filter(row=>'sha256' in row);
assert.notEqual(legacy[0].legacy,legacy[1].legacy,'fixture must reproduce the original coordinate-rendering mismatch');
assert.deepEqual(settings,['0','1'],'canonical comparison must leave the session settings unchanged');
assert.deepEqual(compareFingerprints([source],[restored]),[],'identical rows must match across source and restore settings');
assert.notEqual(source.sha256,changed.sha256,'a change below rounded display precision must remain detectable');
assert.deepEqual(compareFingerprints([source],[changed]),['pg_temp.backup_fingerprint_fixture']);
assert.deepEqual(compareFingerprints([source],[missing]),['pg_temp.backup_fingerprint_fixture']);
console.log('Exact PostgreSQL backup fingerprints passed: different render settings, preserved session settings, sub-display coordinate changes and missing rows. Temporary synthetic rows only.');
