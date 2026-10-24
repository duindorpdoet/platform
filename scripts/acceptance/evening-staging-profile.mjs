// Diagnostic only. Never qualifies as release acceptance or changes settings.
import assert from 'node:assert/strict';
const ref=process.env.SUPABASE_PROJECT_REF,token=process.env.SUPABASE_ACCESS_TOKEN;
assert.equal(process.env.APP_ENVIRONMENT,'staging');
assert.ok(ref&&token);
async function query(sql,readOnly=true){
 const r=await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify({query:sql,read_only:readOnly}),signal:AbortSignal.timeout(60000)});
 if(!r.ok)throw new Error(`PROFILE_SQL_${r.status}`);
 return r.json();
}
const literal=s=>"'"+s.replaceAll("'","''")+"'";
for(const path of ['billing/addons','postgrest']){
 const r=await fetch(`https://api.supabase.com/v1/projects/${ref}/${path}`,{headers:{Authorization:`Bearer ${token}`},signal:AbortSignal.timeout(15000)});
 if(!r.ok){console.log(JSON.stringify({name:path,status:r.status}));continue;}
 const value=await r.json();
 console.log(JSON.stringify(path==='billing/addons'?{name:'compute-selection',selected:value.selected_addons?.filter(a=>a.type==='compute_instance'),available:value.available_addons?.filter(a=>a.type==='compute_instance')}:{name:'rest-pool',settings:Object.fromEntries(Object.entries(value).filter(([key])=>/^(db_pool|db_pool_size|db_pre_request|db_prepared_statements|db_tx_end|db_schema)$/.test(key)))}));
}
// Read both known application environments; never print keys or service secrets.
for(const [environment,project] of [['staging',ref],['production','dtubngvxfbupgvgfrjko']]){
 for(const path of ['config/realtime','billing/addons']){
  const r=await fetch(`https://api.supabase.com/v1/projects/${project}/${path}`,{headers:{Authorization:`Bearer ${token}`},signal:AbortSignal.timeout(15000)});
  if(!r.ok){console.log(JSON.stringify({name:'configured-hosted-limits',environment,path,status:r.status}));continue;}
  const value=await r.json();
  const limits={};
  if(path==='config/realtime')for(const [key,item] of Object.entries(value)){if(typeof item==='number'&&/(max|limit|pool)/i.test(key))limits[key]=item;}
  console.log(JSON.stringify({name:'configured-hosted-limits',environment,path,status:r.status,...(path==='config/realtime'?{limits}:{selected:value.selected_addons?.filter(a=>a.type==='compute_instance')})}));
 }
}
const settings=await query("select name,setting,unit from pg_settings where name in ('jit','jit_above_cost','jit_inline_above_cost','jit_optimize_above_cost','max_connections','shared_buffers','work_mem','effective_cache_size') order by name");
console.log(JSON.stringify({name:'database-settings',settings}));
console.log(JSON.stringify({name:'api-role-settings',rows:await query("select rolname,(select jsonb_agg(c) from unnest(rolconfig) c where c ~ '^(statement_timeout|plan_cache_mode|jit|pgrst.db_pool|pgrst.db_pre_request)=') settings from pg_roles where rolname in ('authenticator','authenticated','postgres')")}));
console.log(JSON.stringify({name:'channel-maintenance-definition',rows:await query("select encode(sha256(convert_to(pg_get_functiondef('app_private.poortkamer_channels(uuid,uuid)'::regprocedure),'UTF8')),'hex') sha256")}));
const restQueries=await query("select query,calls,mean_exec_time from extensions.pg_stat_statements where query like 'WITH pgrst_source AS%' and query ~ '(group_snapshot|portal_room_snapshot|admin_evening_cockpit)' order by total_exec_time desc limit 5");
console.log(JSON.stringify({name:'normalized-rest-query-shapes',queries:restQueries.map(row=>({...row,query:row.query.replace(/[a-f0-9]{8}-[a-f0-9-]{27}/gi,'[uuid]').replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi,'[email]').slice(0,5000)}))}));
const stats=await query(`select case when query like '%portal_room_snapshot%' then 'portal_room_snapshot' when query like '%group_snapshot%' then 'group_snapshot' when query like '%admin_evening_cockpit%' then 'admin_evening_cockpit' when query like '%admin_portal_operations_snapshot%' then 'admin_portal_operations_snapshot' else 'admin_dashboard' end rpc,calls,round(mean_exec_time::numeric,2) mean_ms,round(max_exec_time::numeric,2) maximum_ms,round(total_exec_time::numeric,2) total_ms,shared_blks_hit,shared_blks_read,jit_functions,round(jit_generation_time::numeric,2) jit_generation_ms,round(jit_inlining_time::numeric,2) jit_inlining_ms,round(jit_optimization_time::numeric,2) jit_optimization_ms,round(jit_emission_time::numeric,2) jit_emission_ms from extensions.pg_stat_statements where query ~ '(portal_room_snapshot|group_snapshot|admin_dashboard|admin_evening_cockpit|admin_portal_operations_snapshot)' order by total_exec_time desc limit 15`);
console.log(JSON.stringify({name:'rpc-statistics',stats}));
const fixture=await query("select id,slug from app_private.events where settings->>'eveningLoad'='true' and slug like 'evening-load-%' order by created_at desc limit 1");
assert.equal(fixture.length,1,'an existing owned synthetic event is required');
const event=fixture[0];
const actors=await query(`select 'family' kind,u.id actor,g.id subject from auth.users u join app_private.household_members m on m.user_id=u.id join app_private.registrations r on r.household_id=m.household_id join app_private.group_registrations a on a.registration_id=r.id join app_private.walking_groups g on g.id=a.group_id where g.event_id=${literal(event.id)}::uuid and u.raw_app_meta_data->>'evening_load'=${literal(event.slug)} limit 1`);
actors.push(...await query(`select 'portal' kind,u.id actor,p.id subject from auth.users u join app_private.portal_owners o on o.user_id=u.id join app_private.portals p on p.id=o.portal_id where p.event_id=${literal(event.id)}::uuid and u.raw_app_meta_data->>'evening_load'=${literal(event.slug)} limit 1`));
actors.push(...await query(`select 'admin' kind,u.id actor from auth.users u join app_private.event_capabilities c on c.user_id=u.id where c.event_id=${literal(event.id)}::uuid and c.capability='event_admin' and u.raw_app_meta_data->>'evening_load'=${literal(event.slug)} limit 1`));
assert.equal(actors.length,3,'only the three scoped synthetic roles');
for(const actor of actors){
 const functions=actor.kind==='family'?['group_snapshot']:actor.kind==='portal'?['portal_room_snapshot']:['admin_dashboard','admin_evening_cockpit','admin_portal_operations_snapshot'];
 for(const fn of functions)for(const jit of ['on','off']){
  const args=fn==='group_snapshot'?`${literal(actor.subject)}::uuid`:fn==='portal_room_snapshot'?`${literal(event.slug)},${literal(actor.subject)}::uuid`:literal(event.slug);
  const sql=`begin;set local statement_timeout='15s';set local jit=${jit};set local request.jwt.claims=${literal(JSON.stringify({sub:actor.actor,role:'authenticated'}))};set local role authenticated;explain(analyze,buffers,format json) select api.${fn}(${args});rollback;`;
  const began=performance.now();
  try {
   const result=await query(sql,false);
   const plan=result.find?.(row=>row['QUERY PLAN'])?.['QUERY PLAN']?.[0];
   console.log(JSON.stringify({name:'isolated-rolled-back-snapshot',role:actor.kind,rpc:fn,jit,totalMs:Math.round(performance.now()-began),executionMs:plan?.['Execution Time'],planningMs:plan?.['Planning Time'],buffersHit:plan?.Plan?.['Shared Hit Blocks']}));
  }catch(error){console.log(JSON.stringify({name:'isolated-rolled-back-snapshot',role:actor.kind,rpc:fn,jit,totalMs:Math.round(performance.now()-began),error:error.message}));}
 }
}
console.log(JSON.stringify({name:'profile-complete',diagnosticOnly:true,releaseAcceptance:false}));
const family=actors.find(a=>a.kind==='family');
const burstStarted=performance.now();
const burst=await Promise.all(Array.from({length:8},async()=>{
 const started=performance.now();
 const rows=await query(`begin;set local statement_timeout='15s';set local jit=off;set local request.jwt.claims=${literal(JSON.stringify({sub:family.actor,role:'authenticated'}))};set local role authenticated;explain(analyze,buffers,format json) select api.group_snapshot(${literal(family.subject)}::uuid);rollback;`,false);
 const plan=rows.find?.(row=>row['QUERY PLAN'])?.['QUERY PLAN']?.[0];
 return {totalMs:Math.round(performance.now()-started),executionMs:plan?.['Execution Time']};
}));
console.log(JSON.stringify({name:'eight-parallel-rolled-back-group-reads',elapsedMs:Math.round(performance.now()-burstStarted),requests:burst,diagnosticOnly:true}));
for(const actor of actors)for(const mode of ['auto','force_generic_plan','force_custom_plan']){
 const fn=actor.kind==='family'?'group_snapshot':actor.kind==='portal'?'portal_room_snapshot':'admin_evening_cockpit';
 const args=actor.kind==='family'?`${literal(actor.subject)}::uuid`:actor.kind==='portal'?`${literal(event.slug)},${literal(actor.subject)}::uuid`:literal(event.slug);
 const started=performance.now();
 const rows=await query(`begin;set local statement_timeout='15s';set local jit=off;set local plan_cache_mode=${mode};set local request.jwt.claims=${literal(JSON.stringify({sub:actor.actor,role:'authenticated'}))};set local role authenticated;explain(analyze,buffers,format json) select api.${fn}(${args}) from generate_series(1,20);set constraints all immediate;rollback;`,false);
 const plan=rows.find?.(row=>row['QUERY PLAN'])?.['QUERY PLAN']?.[0];
 console.log(JSON.stringify({name:'twenty-rolled-back-role-reads',role:actor.kind,mode,totalMs:Math.round(performance.now()-started),executionMs:plan?.['Execution Time']}));
}
