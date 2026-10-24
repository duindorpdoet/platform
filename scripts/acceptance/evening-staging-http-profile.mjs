// Isolate HTTP connection setup from application/role load. Not acceptance.
import assert from 'node:assert/strict';
import https from 'node:https';
import {randomUUID} from 'node:crypto';
import {createClient} from '@supabase/supabase-js';
import {makeEveningLoadFixture,eveningLoadFixtureSql} from './evening-load-fixture.mjs';
const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,secret=process.env.SUPABASE_SERVICE_ROLE_KEY;
assert.equal(process.env.APP_ENVIRONMENT,'staging');
assert.equal(new URL(url).hostname,`${process.env.SUPABASE_PROJECT_REF}.supabase.co`);
const admin=createClient(url,secret,{auth:{persistSession:false,autoRefreshToken:false}}),created=[];
const fixture=makeEveningLoadFixture();
let session;
const sessions=[];
const p=n=>samples=>Math.round([...samples].sort((a,b)=>a-b)[Math.max(0,Math.ceil(samples.length*n)-1)]??0);
try {
 for(let offset=0;offset<fixture.actors.length;offset+=5)await Promise.all(fixture.actors.slice(offset,offset+5).map(async actor=>{const r=await admin.auth.admin.createUser({id:actor.id,email:actor.email,password:actor.password,email_confirm:true,app_metadata:{evening_load:fixture.slug}});if(r.error)throw new Error(`HTTP_PROFILE_ACCOUNT_${r.error.code}`);assert.equal(r.data.user.id,actor.id);created.push(actor);}));
 const setup=await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_REF}/database/query`,{method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`,'Content-Type':'application/json'},body:JSON.stringify({query:eveningLoadFixtureSql(fixture),read_only:false}),signal:AbortSignal.timeout(60000)});
 assert.ok(setup.ok,'isolated fixture setup');
 const family=fixture.actors.find(a=>a.kind==='family'),client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
 const login=await client.auth.signInWithPassword({email:family.email,password:family.password});if(login.error)throw new Error(`HTTP_PROFILE_LOGIN_${login.error.code}`);session=login.data.session;sessions.push(session);
 const target=new URL('/rest/v1/rpc/group_snapshot',url),body=JSON.stringify({_group_id:family.groupId});
 const headers={apikey:key,Authorization:`Bearer ${session.access_token}`,'Content-Type':'application/json','Content-Profile':'api','Accept-Profile':'api'};
 for(const transport of ['native-fetch','https-16-sockets','https-254-sockets']){
  const agent=transport==='native-fetch'?null:new https.Agent({keepAlive:true,maxSockets:transport==='https-16-sockets'?16:254});
  const started=performance.now(),samples=[];
  try {
   await Promise.all(Array.from({length:254},async()=>{
    const began=performance.now();
    if(!agent){try{const r=await fetch(target,{method:'POST',headers,body,signal:AbortSignal.timeout(12000)});const bytes=(await r.arrayBuffer()).byteLength;samples.push({status:r.status,total:performance.now()-began,bytes});}catch(error){samples.push({status:0,total:performance.now()-began,error:error.name});}return;}
    await new Promise(resolve=>{
     let socketAt,connectedAt,headersAt,bytes=0,settled=false;
     const done=(status,error)=>{if(settled)return;settled=true;clearTimeout(deadline);samples.push({status,total:performance.now()-began,queue:(socketAt??began)-began,connect:connectedAt&&socketAt?connectedAt-socketAt:0,server:headersAt&&connectedAt?headersAt-connectedAt:0,bytes,error});resolve();};
     const request=https.request(target,{method:'POST',headers,agent},response=>{headersAt=performance.now();response.on('data',chunk=>{bytes+=chunk.length;});response.on('end',()=>done(response.statusCode));response.on('error',()=>done(0,'RESPONSE_ERROR'));});
     const deadline=setTimeout(()=>request.destroy(new Error('PROFILE_DEADLINE')),12000);
     request.on('socket',socket=>{socketAt=performance.now();if(request.reusedSocket)connectedAt=socketAt;else socket.once('secureConnect',()=>{connectedAt=performance.now();});});
     request.on('error',error=>done(0,error.message==='PROFILE_DEADLINE'?'DEADLINE':error.code));request.end(body);
    });
   }));
  }finally{agent?.destroy();}
  const statuses={};for(const s of samples)statuses[s.status]=(statuses[s.status]??0)+1;
  console.log(JSON.stringify({name:'synthetic-http-transport-profile',transport,logicalRequests:254,distinctAccounts:1,elapsedMs:Math.round(performance.now()-started),statuses,p50Ms:p(.5)(samples.map(s=>s.total)),p95Ms:p(.95)(samples.map(s=>s.total)),maximumMs:p(1)(samples.map(s=>s.total)),queueP95Ms:p(.95)(samples.map(s=>s.queue??0)),connectP95Ms:p(.95)(samples.map(s=>s.connect??0)),serverP95Ms:p(.95)(samples.map(s=>s.server??0)),maximumBytes:Math.max(...samples.map(s=>s.bytes??0)),diagnosticOnly:true,releaseAcceptance:false}));
 }
 const roleActors={family:{actor:family,session}};
 for(const kind of ['portal','admin']){const actor=fixture.actors.find(a=>a.kind===kind),c=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}}),r=await c.auth.signInWithPassword({email:actor.email,password:actor.password});if(r.error)throw new Error(`HTTP_PROFILE_ROLE_LOGIN_${r.error.code}`);sessions.push(r.data.session);roleActors[kind]={actor,session:r.data.session};}
 const calls=[];
 for(let i=0;i<200;i++)calls.push({kind:'family',rpc:'group_snapshot',args:{_group_id:family.groupId}});
 for(let i=0;i<30;i++)calls.push({kind:'portal',rpc:'portal_room_snapshot',args:{_event_slug:fixture.slug,_portal_id:roleActors.portal.actor.portalId}});
 for(let i=0;i<24;i++)for(const rpc of ['admin_dashboard','admin_evening_cockpit','admin_portal_operations_snapshot'])calls.push({kind:'admin',rpc,args:{_event_slug:fixture.slug}});
 const mixed=[];
 await Promise.all(calls.map(async call=>{const start=performance.now();try{const r=await fetch(new URL(`/rest/v1/rpc/${call.rpc}`,url),{method:'POST',headers:{...headers,Authorization:`Bearer ${roleActors[call.kind].session.access_token}`},body:JSON.stringify(call.args),signal:AbortSignal.timeout(12000)});const bytes=(await r.arrayBuffer()).byteLength;mixed.push({rpc:call.rpc,status:r.status,ms:performance.now()-start,bytes});}catch{mixed.push({rpc:call.rpc,status:0,ms:performance.now()-start,bytes:0});}}));
 for(const rpc of new Set(mixed.map(s=>s.rpc))){const values=mixed.filter(s=>s.rpc===rpc),statuses={};for(const s of values)statuses[s.status]=(statuses[s.status]??0)+1;console.log(JSON.stringify({name:'three-account-mixed-role-profile',distinctAccounts:3,rpc,requests:values.length,statuses,p95Ms:p(.95)(values.map(s=>s.ms)),maximumBytes:Math.max(...values.map(s=>s.bytes)),diagnosticOnly:true,releaseAcceptance:false}));}
}finally{
 async function cleanup(command){for(let attempt=0;attempt<5;attempt++){try{const r=await command();if(!r.error)return r;}catch{}if(attempt<4)await new Promise(resolve=>setTimeout(resolve,250*2**attempt));}return null;}
 const signedOut=(await Promise.all(sessions.map(session=>cleanup(()=>admin.auth.admin.signOut(session.access_token,'global'))))).every(Boolean);
 let secured=0;
 for(let offset=0;offset<created.length;offset+=4)await Promise.all(created.slice(offset,offset+4).map(async actor=>{const r=await cleanup(()=>admin.auth.admin.updateUserById(actor.id,{ban_duration:'876000h',password:randomUUID()+randomUUID()}));if(r&&Date.parse(r.data.user.banned_until)>Date.now()+86400000)secured++;}));
 console.log(JSON.stringify({name:'http-profile-cleanup',created:created.length,secured}));
 assert.equal(secured,created.length,'all temporary HTTP probe accounts secured');
 assert.ok(signedOut,'synthetic profile session revoked');
}
