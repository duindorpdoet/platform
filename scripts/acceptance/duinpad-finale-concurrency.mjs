// Local simulation only. No HTTP, provider, relay or physical output.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync, spawn } from 'node:child_process';
const container=process.env.DUINPAD_TEST_CONTAINER;
const database=process.env.DUINPAD_TEST_DATABASE;
if(!/^supabase_db_[a-zA-Z0-9_-]+$/.test(container??'')||!/^duinpad_[a-zA-Z0-9_]+$/.test(database??''))throw Error('DEDICATED_LOCAL_DUINPAD_DATABASE_REQUIRED');
const args=['exec','-i',container,'psql','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1','-Atq'];
const sql=query=>execFileSync('docker',args,{input:query,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim();
const parallel=query=>new Promise((resolve,reject)=>{const proc=spawn('docker',args,{stdio:['pipe','pipe','pipe']});let out='',err='';proc.stdout.on('data',b=>out+=b);proc.stderr.on('data',b=>err+=b);proc.on('error',reject);proc.on('close',code=>code?reject(Error(err)):resolve(out.trim()));proc.stdin.end(query);});
assert.equal(sql("select count(*) from app_private.duinpad_finale_receipts"),'0','requires an unused dedicated fixture database');
sql(`begin;${readFileSync(new URL('../../supabase/tests/fixtures/duinpad-finalists.inc',import.meta.url),'utf8')}commit;`);
const claims=i=>`select set_config('request.jwt.claims','{"sub":"d1000000-0000-0000-0000-${String(i).padStart(12,'0')}","role":"authenticated"}',true);`;
const party='{"d9000000-0000-0000-0000-000000000001":"visited","d9000000-0000-0000-0000-000000000002":"skipped"}';
const standalone='{"d9000000-0000-0000-0000-000000000003":"skipped"}';
const call=(i,choices)=>`begin;set local role authenticated;${claims(i)}select api.duinpad_finale_confirm('duindorp-halloween-2026','DUINPAD-SIM-FINALE-TOKEN','${choices}','race-finale-${i}');select pg_sleep(0.05);commit;`;
const raw=await Promise.all([parallel(call(1,party)),parallel(call(2,party)),parallel(call(3,standalone))]);
const results=raw.map(out=>out.split('\n').filter(Boolean).map(line=>{try{return JSON.parse(line);}catch{return null;}}).find(value=>value?.receiptId));
assert.equal(results.filter(value=>value.duplicate===false).length,2);
assert.equal(results.filter(value=>value.duplicate===true).length,1);
assert.equal(results[0].receiptId,results[1].receiptId);
assert.equal(new Set(results.map(value=>value.eveningEndsAt)).size,1);
assert.equal(sql('select count(*) from app_private.duinpad_finale_receipts'),'2');
assert.equal(sql("select evening_ends_at=first_finale_scan_at+interval '2 hours' from app_private.duinpad_evenings"),'t');
assert.equal(sql("select count(*) from app_private.run_stop_arrivals where run_id='d8000000-0000-0000-0000-000000000001'"),'3');
assert.equal(sql("select count(*) from app_private.poortenboek_passport_seals where run_id='d8000000-0000-0000-0000-000000000001'"),'3');
// A request may begin before the deadline and wait on another group lock.
// It must recheck actual database time after all locks, before accepting a scan.
// A late accepted adult is deliberately outside the immutable mail cohort; the
// actual run deadline must still hold when this account waits across it.
sql("insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data)values('d1000000-0000-0000-0000-000000000005','new-adult@example.invalid',now(),'{}','{}');insert into app_private.household_members(household_id,user_id,relation_role)values('d2000000-0000-0000-0000-000000000003','d1000000-0000-0000-0000-000000000005','adult');");
assert.equal(sql("select count(*)from app_private.duinpad_evening_members where account_id='d1000000-0000-0000-0000-000000000005'"),'0');
sql("begin;alter table app_private.duinpad_evenings disable trigger duinpad_evening_immutable;update app_private.duinpad_evenings set first_finale_scan_at=statement_timestamp()-interval '2 hours'+interval '1 second',evening_ends_at=statement_timestamp()+interval '1 second';alter table app_private.duinpad_evenings enable trigger duinpad_evening_immutable;commit;");
let markReady;
const ready=new Promise(resolve=>{markReady=resolve;});
const lock=spawn('docker',args,{stdio:['pipe','pipe','pipe']});let lockOut='',lockErr='';
const lockDone=new Promise((resolve,reject)=>{lock.stdout.on('data',b=>{lockOut+=b;if(lockOut.includes('DUINPAD_TEST_LOCK_HELD'))markReady();});lock.stderr.on('data',b=>lockErr+=b);lock.on('error',reject);lock.on('close',code=>code?reject(Error(lockErr)):resolve());});
lock.stdin.end("begin;select pg_advisory_xact_lock(hashtextextended((select id::text||':duinpad-finale' from app_private.events where slug='duindorp-halloween-2026'),0));select 'DUINPAD_TEST_LOCK_HELD';select pg_sleep(1.5);commit;");
await ready;
const crossing=`begin;do $$begin if clock_timestamp()>=(select evening_ends_at from app_private.duinpad_evenings)then raise exception 'TEST_STARTED_TOO_LATE';end if;end$$;set local role authenticated;${claims(5)}select api.duinpad_finale_confirm('duindorp-halloween-2026','DUINPAD-SIM-FINALE-TOKEN','${standalone}','deadline-lock-crossing');commit;`;
await assert.rejects(parallel(crossing),/EVENING_ENDED/);
await lockDone;
assert.equal(sql('select count(*) from app_private.duinpad_finale_receipts'),'2','waiting over the deadline creates no late receipt');
// An offline browser is irrelevant: the server deadline is made due only within
// this dedicated fixture database, with no application clock override.
sql("begin;alter table app_private.duinpad_evenings disable trigger duinpad_evening_immutable;update app_private.duinpad_evenings set first_finale_scan_at=statement_timestamp()-interval '2 hours 1 second',evening_ends_at=statement_timestamp()-interval '1 second';alter table app_private.duinpad_evenings enable trigger duinpad_evening_immutable;commit;");
const workers=await Promise.all([parallel('begin;select api.worker_duinpad_evenings();select pg_sleep(0.05);commit;'),parallel('begin;select api.worker_duinpad_evenings();commit;')]);
const queued=workers.map(out=>out.split('\n').filter(Boolean).map(line=>JSON.parse(line)).find(value=>typeof value?.queued==='number').queued);
assert.equal(queued.reduce((sum,n)=>sum+n,0),4);
assert.equal(sql("select count(*) from app_private.email_outbox where message_type='duinpad_evening_thanks'"),'4');
assert.equal(sql("select api.worker_duinpad_evenings()->>'queued'"),'0');
console.log(JSON.stringify({code:'DUINPAD_FINALE_CONCURRENCY_VERIFIED',environment:'dedicated local PostgreSQL, synthetic fixtures',concurrentScans:3,uniqueReceipts:2,oneUnchangedDeadline:true,lockWaitCrossingDeadlineRejected:true,lateAdultOutsideFrozenCohort:true,arrivals:3,seals:3,concurrentWorkers:2,uniqueClosingMails:4,realMail:false,relay:false,hardware:false}));
