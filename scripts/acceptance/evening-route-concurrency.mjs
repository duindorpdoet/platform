import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {requireLocalTogetherDatabase,sql} from './together-fixtures.mjs';
import {prepareStartedLegacyFixtures} from './started-fixtures.mjs';
const container=requireLocalTogetherDatabase();
prepareStartedLegacyFixtures();
const group='23000000-0000-0000-0000-000000000002';
const claims=actor=>`set local role authenticated;select set_config('request.jwt.claims','{"sub":"${actor}","role":"authenticated"}',true);`;
const before=sql(`select jsonb_build_object('runs',(select count(*) from app_private.group_runs),'evidence',(select count(*) from app_private.evening_readiness_evidence),'group',(select to_jsonb(g) from app_private.walking_groups g where id='${group}'),'portal',(select to_jsonb(p) from app_private.portals p where id='12000000-0000-0000-0000-000000000001'))`);
function transaction(query,onOutput=()=>{}) {
 let output='',error='';
 const child=spawn('docker',['exec','-i',container,'psql','-U','postgres','-d','postgres','-X','-qAt','-v','ON_ERROR_STOP=1']);
 const done=new Promise((resolve,reject)=>{child.stdout.on('data',data=>{output+=data;onOutput(output);});child.stderr.on('data',data=>{error+=data;});child.on('error',reject);child.on('close',code=>code===0?resolve(output):reject(new Error(error||`Transaction exited ${code}`)));});
 child.stdin.end(query);return done;
}
async function contend(eventAction,observerAction,commit=false,resourceLock="select 1 from app_private.events where slug='duindorp-halloween-2026' for update;") {
 const observerName='evening-readiness-'+randomUUID();
 let observed,barrierFailed,observer;
 const observerReady=new Promise((resolve,reject)=>{observed=resolve;barrierFailed=reject;});
 const route=transaction(`begin;
  set local lock_timeout='4s';set local statement_timeout='8s';
  ${resourceLock}
  select 'EVENT_LOCKED';
  do $$begin
   for tick in 1..200 loop
    perform pg_stat_clear_snapshot();
    if exists(select 1 from pg_stat_activity where application_name='${observerName}' and wait_event_type='Lock') then return; end if;
    perform pg_sleep(.01);
   end loop;
   raise exception 'OBSERVER_DID_NOT_CONTEND';
  end $$;
  ${eventAction}
  ${commit?'commit':'rollback'};`,output=>{
   if(!output.includes('EVENT_LOCKED')||observer)return;
   observer=transaction(`begin;set local lock_timeout='4s';set local statement_timeout='8s';set local application_name='${observerName}';${observerAction} rollback;`);
   observed();
  });
 const routeOutcome=route.then(value=>{if(!observer)barrierFailed(new Error('EVENT_BARRIER_NOT_REACHED'));return {value};},error=>{if(!observer)barrierFailed(error);return {error};});
 await observerReady;
 return Promise.all([routeOutcome,observer.then(value=>({value}),error=>({error}))]);
}
const [route,observation]=await contend(`
 create temp table route_args as select g.version,array_agg(c.id order by c.id) children from app_private.walking_groups g
 join app_private.group_registrations a on a.group_id=g.id and a.superseded_at is null
 join app_private.registration_children c on c.registration_id=a.registration_id and c.participation_status='active'
 where g.id='${group}' group by g.version;
 grant select on route_args to authenticated;
 ${claims('c0000000-0000-0000-0000-000000000001')}
 select api.run_start('${group}',children,version,'${randomUUID()}','concurrent-actual-start') from route_args;`,
 `${claims('a0000000-0000-0000-0000-000000000005')}
 select api.record_evening_readiness('group','${group}','account_opened','observed',null,null,'{}',true,'${randomUUID()}');`);
assert.ifError(route.error);assert.ifError(observation.error);assert.match(route.value,/runId/);assert.match(observation.value,/observed/);
// A stock action holds its own portal while a route/status writer waits for it.
// Its event FK must remain compatible with that writer's NO KEY UPDATE lock.
const portalVersion=sql("select version from app_private.portals where id='12000000-0000-0000-0000-000000000001'");assert.match(portalVersion,/^[0-9]+$/);
const [stock,status]=await contend(`${claims('e0000000-0000-0000-0000-000000000001')}
 select api.portal_room_update('12000000-0000-0000-0000-000000000001','stock','{"stock":"plenty"}','${randomUUID()}');`,
 `${claims('f0000000-0000-0000-0000-000000000001')}
 select api.portal_set_operational_state('12000000-0000-0000-0000-000000000001','paused',${portalVersion},'Synthetische gelijktijdige statuscontrole');`,false,
 "select 1 from app_private.portals where id='12000000-0000-0000-0000-000000000001' for update;");
assert.ifError(stock.error);assert.ifError(status.error);
// Revoke only a dedicated synthetic actor while its own command waits on the event.
// The command must authorize after the wait, not keep the earlier role decision.
const actor=randomUUID();
try {
 sql(`insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data) values('${actor}','authenticated','authenticated','readiness-${actor}@example.invalid','{}','{}');
  insert into app_private.event_capabilities(event_id,user_id,capability,granted_by) select id,'${actor}','groups_manage','f0000000-0000-0000-0000-000000000001' from app_private.events where slug='duindorp-halloween-2026';`);
 const revision=sql(`select app_private.evening_readiness_revision('group','${group}','account_opened')`);
 assert.match(revision,/^account:[0-9a-f-]+:group:[0-9a-f-]+$/);
 const [revocation,attempt]=await contend(`update app_private.event_capabilities set revoked_at=clock_timestamp() where user_id='${actor}';`,
  `${claims(actor)}select api.record_evening_readiness('group','${group}','account_opened','manual','${revision}','Synthetische contactverklaring','{"confirmed":true}',true,'${randomUUID()}');`,true);
 assert.ifError(revocation.error);assert.ok(attempt.error);assert.match(attempt.error.message,/NOT_AUTHORIZED/);
} finally {
 sql(`delete from app_private.event_capabilities where user_id='${actor}';delete from auth.users where id='${actor}';`);
}
const after=sql(`select jsonb_build_object('runs',(select count(*) from app_private.group_runs),'evidence',(select count(*) from app_private.evening_readiness_evidence),'group',(select to_jsonb(g) from app_private.walking_groups g where id='${group}'),'portal',(select to_jsonb(p) from app_private.portals p where id='12000000-0000-0000-0000-000000000001'))`);
assert.equal(after,before);
// Hold every existing shared channel row in one open transaction. Reading a
// different resource must finish before that holder releases its locks.
sql("select app_private.poortkamer_channels((select id from app_private.events where slug='duindorp-halloween-2026'),'12000000-0000-0000-0000-000000000001');");
const channelHolder=spawn('docker',['exec','-i',container,'psql','-U','postgres','-d','postgres','-X','-qAt','-v','ON_ERROR_STOP=1']);
let channelOutput='',channelError='';
const channelReady=new Promise((resolve,reject)=>{
 channelHolder.stdout.on('data',data=>{channelOutput+=data;if(channelOutput.includes('CHANNEL_ROWS_LOCKED'))resolve();});
 channelHolder.on('error',reject);
 channelHolder.on('close',()=>{if(!channelOutput.includes('CHANNEL_ROWS_LOCKED'))reject(new Error(channelError||'CHANNEL_BARRIER_NOT_REACHED'));});
});
const channelDone=new Promise((resolve,reject)=>{
 channelHolder.stderr.on('data',data=>{channelError+=data;});
 channelHolder.on('error',reject);
 channelHolder.on('close',code=>code===0?resolve():reject(new Error(channelError||'CHANNEL_HOLDER_FAILED')));
});
channelHolder.stdin.write("begin;set local idle_in_transaction_session_timeout='10s';select id from app_private.portal_room_channels where event_id=(select id from app_private.events where slug='duindorp-halloween-2026') and portal_id is null for update;select 'CHANNEL_ROWS_LOCKED';\n");
try {
 await channelReady;
 const room=await transaction(`begin;set local statement_timeout='2s';${claims('e0000000-0000-0000-0000-000000000001')}select api.portal_room_snapshot('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001');rollback;`);
 assert.match(room,/portalTopic/,'actual owner snapshot completes while the shared rows remain locked');
} finally {
 channelHolder.stdin.end('rollback;\n');
 await channelDone;
}
console.log(JSON.stringify({status:'pass',checks:['actual run start and own readiness observation complete without event/subject deadlock','independent portal stock and route status writes complete without an event-FK deadlock','role revoked during an event-lock wait cannot record a manual attestation','rolled-back test actions and synthetic actor cleanup preserve existing runs, evidence and group','actual owner snapshot completes before a competing shared-channel lock is released']}));
