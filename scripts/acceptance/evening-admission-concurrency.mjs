import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {createClient} from '@supabase/supabase-js';
import {requireLocalTogetherDatabase,sql} from './together-fixtures.mjs';

// Actual Auth + HTTP RPCs on two connections behind an observed PostgreSQL
// event-lock barrier. Only fresh, isolated local fixtures are permitted.
const container=requireLocalTogetherDatabase(),event='duindorp-halloween-2026';
const groups=['23000000-0000-0000-0000-000000000001','23000000-0000-0000-0000-000000000002'];
const portal='12000000-0000-0000-0000-000000000028',finale='12000000-0000-0000-0000-000000000030';
assert.equal(sql(`select count(*) from app_private.group_runs where group_id=any(array['${groups.join("','")}']::uuid[])`),'0','requires fresh isolated fixtures');
const protectedRows=()=>sql(`select jsonb_build_object('plans',(select md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id),'[]')::text) from app_private.route_plan_stops p),'payments',(select md5(coalesce(jsonb_agg(to_jsonb(p) order by p.id),'[]')::text) from app_private.payment_requests p),'credentials',(select md5(coalesce(jsonb_agg(to_jsonb(c) order by c.id),'[]')::text) from app_private.portal_credentials c))`);
const before=protectedRows();
sql(`begin;
 update app_private.portal_windows set opens_at=now()-interval '1 hour',closes_at=now()+interval '5 hours';
 update app_private.start_slots set starts_at=now()-interval '1 minute';
 update app_private.event_route_settings set first_start_at=now()-interval '1 hour',global_ordinary_stop_at=now()+interval '2 hours',allowed_personal_stop_times=array[now()+interval '1 hour'],ordinary_visit_seconds=60,route_buffer_seconds=0,final_portal_id='${finale}',finale_opens_at=now()-interval '1 hour',finale_last_arrival_at=now()+interval '4 hours',finale_closes_at=now()+interval '5 hours',finale_show_seconds=60,finale_turnover_seconds=120,finale_max_concurrent_groups=10,finale_max_concurrent_children=40,finale_available=true,planner_mode='dynamic' where event_id=(select id from app_private.events where slug='${event}');
 update app_private.portals set operation_status='closed' where id not in ('${portal}','${finale}');
 update app_private.portal_windows set max_children_per_visit=6,max_concurrent_groups=1,visit_minutes=1,buffer_minutes=0 where portal_id='${portal}';
 insert into app_private.group_schedule_revisions(group_id,revision,state,start_slot_id,effective_ordinary_stop_at,expected_finale_arrival_at,preference_match,published_at)
 select g.id,coalesce((select max(s.revision) from app_private.group_schedule_revisions s where s.group_id=g.id),0)+1,'published',g.start_slot_id,now()+interval '2 hours',now()+interval '3 hours','neutral',now() from app_private.walking_groups g where g.id=any(array['${groups.join("','")}']::uuid[]);
 update app_private.walking_groups g set route_mode='dynamic',desired_ordinary_visits=1,current_schedule_revision_id=(select id from app_private.group_schedule_revisions s where s.group_id=g.id order by revision desc limit 1) where g.id=any(array['${groups.join("','")}']::uuid[]);
 commit;`);
const clients=await Promise.all(groups.map(async()=>{
 const client=createClient(process.env.NEXT_PUBLIC_SUPABASE_URL,process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,{auth:{persistSession:false,autoRefreshToken:false},global:{fetch:(input,init)=>fetch(input,{...init,signal:AbortSignal.timeout(12_000)})}});
 assert.equal((await client.auth.signInWithPassword({email:'leader-a@example.invalid',password:'local-test-only'})).error,null);return client;
}));
async function rpc(index,name,args){const result=await clients[index].schema('api').rpc(name,args);assert.equal(result.error,null,`${name}: ${result.error?.message}`);return result.data;}
for(let i=0;i<groups.length;i++){
 const snapshot=await rpc(i,'group_snapshot',{_group_id:groups[i]}),roster=await rpc(i,'group_roster',{_group_id:groups[i]});
 await rpc(i,'run_start',{_group_id:groups[i],_present_registration_child_ids:roster.map(child=>child.registrationChildId),_expected_group_version:snapshot.group.version,_idempotency_key:randomUUID(),_request_hash:'isolated-actual-early-admission'});
 const state=await rpc(i,'group_snapshot',{_group_id:groups[i]});assert.equal(state.run.currentStop.portal.id,portal);
 const minute=i===0?90:100;
 sql(`update app_private.portal_reservations set reserved_from=now()+interval '${minute} minutes',service_until=now()+interval '${minute+1} minutes',reserved_until=now()+interval '${minute+1} minutes' where run_id='${state.run.id}' and kind='ordinary' and status='active';`);
}
const snapshots=await Promise.all(groups.map((group,i)=>rpc(i,'group_snapshot',{_group_id:group})));
const commands=snapshots.map(s=>({_run_id:s.run.id,_expected_stop_id:s.run.currentStop.id,_expected_run_version:s.run.version,_credential:'TEST-PORTAL-28-TOKEN',_method:'qr'}));
const bookings=()=>sql(`select md5(jsonb_agg(to_jsonb(b) order by b.id)::text) from app_private.portal_reservations b where b.run_id=any(array['${snapshots.map(s=>s.run.id).join("','")}']::uuid[])`);
const beforeBookings=bookings();
assert.equal(sql(`select count(*) from app_private.portal_reservations a join app_private.portal_reservations b on a.portal_id=b.portal_id and a.group_id<>b.group_id and a.reserved_from<b.reserved_until and a.reserved_until>b.reserved_from where a.kind='ordinary' and b.kind='ordinary' and a.status='active' and b.status='active'`),'0','expected reception intervals do not overlap');
let attempts;
const holder=spawn('docker',['exec','-i',container,'psql','-U','postgres','-d','postgres','-X','-qAt','-v','ON_ERROR_STOP=1']);
let output='',error='';
const held=new Promise((resolve,reject)=>{holder.stdout.on('data',chunk=>{output+=chunk;if(output.includes('ADMISSION_LOCKED')&&!attempts)attempts=Promise.all(clients.map((client,i)=>client.schema('api').rpc('run_scan',commands[i])));});holder.stderr.on('data',chunk=>{error+=chunk;});holder.on('error',reject);holder.on('close',code=>code===0?resolve():reject(new Error(error||`Barrier exited ${code}`)));});
holder.stdin.end(`begin;set local statement_timeout='10s';
 select 1 from app_private.events where slug='${event}' for no key update;
 select 'ADMISSION_LOCKED';
 do $$begin for tick in 1..500 loop
  perform pg_stat_clear_snapshot();
  if (select count(*) from pg_stat_activity where usename='authenticator' and wait_event_type='Lock' and query like '%run_scan%')>=2 then return;end if;
  perform pg_sleep(.01);
 end loop;raise exception 'TWO_HTTP_SCANS_DID_NOT_CONTEND';end $$;
 select 'ADMISSION_RELEASE_AT:'||clock_timestamp();commit;`);
await held;assert.ok(attempts,'two actual authenticated HTTP requests reached the barrier');
const results=await attempts,winner=results.findIndex(result=>!result.error),loser=1-winner;
assert.equal(results.filter(result=>!result.error).length,1);assert.equal(results[loser].error?.message,'PORTAL_CAPACITY_EXCEEDED');
const witness=output.match(/ADMISSION_RELEASE_AT:([^\n]+)/)?.[1];assert.ok(witness);
const physical=JSON.parse(sql(`select jsonb_build_object('scans',(select count(*) from app_private.scan_evidence),'arrivals',(select count(*) from app_private.run_stop_arrivals),'seals',(select count(*) from app_private.poortenboek_passport_seals),'scannedAt',(select min(scanned_at) from app_private.scan_evidence))`));
assert.equal(physical.scans,1);assert.equal(physical.arrivals,0);assert.equal(physical.seals,0);assert.ok(Date.parse(physical.scannedAt)>=Date.parse(witness),'proof uses actual server time after the observed wait');assert.equal(bookings(),beforeBookings,'early admission does not rewrite either fixed forecast');
const blocked=await clients[loser].schema('api').rpc('run_scan_validate',commands[loser]);assert.equal(blocked.error?.message,'PORTAL_CAPACITY_EXCEEDED');
async function complete(index){const s=await rpc(index,'group_snapshot',{_group_id:groups[index]});return rpc(index,'run_arrive_and_advance',{...commands[index],_participant_choices:Object.fromEntries(s.run.participants.filter(p=>p.attendance==='present'&&!p.departedAt).map(p=>[p.id,'skipped'])),_idempotency_key:randomUUID()});}
await complete(winner);await rpc(loser,'run_scan',commands[loser]);await complete(loser);
const final=JSON.parse(sql(`select jsonb_build_object('scans',(select count(*) from app_private.scan_evidence),'arrivals',(select count(*) from app_private.run_stop_arrivals),'seals',(select count(*) from app_private.poortenboek_passport_seals),'present',(select count(*) from app_private.run_participants where attendance='present' and departed_at is null))`));
assert.equal(final.scans,2);assert.equal(final.arrivals,final.present);assert.equal(final.seals,final.present);assert.equal(protectedRows(),before);
console.log(JSON.stringify({status:'pass',checks:['two real Auth sessions and HTTP scans observed waiting on the event lock','nonoverlapping expected bookings still share actual physical capacity','exactly one simultaneous early scan is accepted','accepted proof is timestamped after the lock wait','no false arrival or seal for the rejected scan','completion releases the physical slot for the second group','all present outside children retain real arrivals and inclusive seals','original plans, payments and QR credentials remain exact']}));
