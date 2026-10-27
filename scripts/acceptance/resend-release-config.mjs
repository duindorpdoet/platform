// Isolated rollback test of configuration mutation only. No gateway or mail API.
import {sql,requireLocalTogetherDatabase} from './together-fixtures.mjs';
import {activationQuery} from '../deploy/activate-resend-release.mjs';
requireLocalTogetherDatabase();
const env={APP_ENVIRONMENT:'test',GITHUB_SHA:'a'.repeat(40),MAIL_TEST_WAIVER_REASON:'Isolated rollback fixture',MAIL_TEST_WAIVER_EXPIRES_AT:new Date(Date.now()+3600000).toISOString()};
// All configuration mutation assertions run in one rollback transaction.
const setup=`select api.worker_mail_bootstrap('test','release@example.invalid','De Poorten','reply@example.invalid');
insert into app_private.mail_config_versions(id,environment,version,provider,from_email,from_name,reply_to,config_hash) values('e1000000-0000-0000-0000-000000000001','test',2,'resend','draft@example.invalid','Unrelated draft','draft@example.invalid','unrelated-draft');
update app_private.mail_config_heads set draft_id='e1000000-0000-0000-0000-000000000001',suppressions_imported_at=now(),suppression_import_hash=repeat('b',64) where environment='test';
insert into app_private.mail_suppressions(environment,recipient_hash,reason,provider) values('test',extensions.digest('blocked@example.invalid','sha256'),'bounce','sendgrid');
insert into app_private.mail_envelopes(environment,logical_key,config_id,provider,channel,message_type,recipient_hash,payload_hash,credential_hash,status)
select 'test','release-preserved-unknown',active_id,'sendgrid','transactional','fixture',extensions.digest('unknown@example.invalid','sha256'),'fixture','fixture','unknown' from app_private.mail_config_heads where environment='test';`;
if(sql("select count(*) from app_private.mail_config_heads where environment='test';")!=='0')throw new Error('TEST_ENVIRONMENT_ALREADY_IN_USE');
// Discover the random active ID in a committed local bootstrap, then remove it
// after the atomic rollback checks. Test environment has no live data or worker.
sql("select api.worker_mail_bootstrap('test','release@example.invalid','De Poorten','reply@example.invalid');");
const before=JSON.parse(sql("select json_build_object('revision',revision,'active_id',active_id) from app_private.mail_config_heads where environment='test';"));
const checks=`do $check$ declare h app_private.mail_config_heads; c app_private.mail_config_versions;begin
select * into h from app_private.mail_config_heads where environment='test';select * into c from app_private.mail_config_versions where id=h.active_id;
if c.provider<>'resend' or c.from_email<>'release@example.invalid' or c.from_name<>'De Poorten' or c.reply_to<>'reply@example.invalid' then raise exception 'SENDER_OR_PROVIDER_CHANGED';end if;
if h.draft_id<>'e1000000-0000-0000-0000-000000000001'::uuid or h.revision<>1 then raise exception 'DRAFT_OR_REVISION_CHANGED';end if;
if not exists(select 1 from app_private.mail_envelopes where logical_key='release-preserved-unknown' and provider='sendgrid' and status='unknown' and config_id='${before.active_id}') then raise exception 'OLD_ATTEMPT_CHANGED';end if;
if (select count(*) from app_private.mail_suppressions where environment='test')<>1 then raise exception 'SUPPRESSIONS_CHANGED';end if;
if not exists(select 1 from app_private.audit_events where action='mail.config.release_activate' and minimal_change->>'deliveryValidated'='false' and minimal_change->>'release'='${env.GITHUB_SHA}') then raise exception 'RELEASE_AUDIT_MISSING';end if;
end $check$;`;
try{
 const first=activationQuery(env,before);
 // UUID for the new active version is generated in SQL: capture it using a
 // transaction-local psql variable before calling the same query a second time.
 const rerun=activationQuery(env,{revision:1,active_id:'e2000000-0000-0000-0000-000000000002'}).replaceAll("'e2000000-0000-0000-0000-000000000002'::uuid","(select active_id from app_private.mail_config_heads where environment='test')");
 sql(`begin;${setup}${first}${checks}${rerun}${checks}rollback;`);
 let refused=false;try{sql(`begin;${setup}update app_private.mail_config_heads set suppressions_imported_at=null where environment='test';${first}rollback;`);}catch{refused=true;}
 if(!refused)throw new Error('MISSING_IMPORT_WAS_ACCEPTED');
 console.log('Resend release SQL: sender/draft/suppressions/unknown-attempt preservation, audited no-delivery exception, idempotent retry and missing-import refusal passed (isolated rollback).');
}finally{
 sql(`begin;delete from app_private.mail_config_heads where environment='test';delete from app_private.mail_config_versions where environment='test' and id='${before.active_id}';commit;`);
}
