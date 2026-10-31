import 'server-only';
import { createHash, randomUUID } from 'node:crypto';
import { serverEnv } from '@/lib/config/server-env';
import { createPrivilegedClient } from '@/lib/supabase/privileged';
import { ApiError } from '@/lib/http/api';
export type ShowStatus='requested'|'registered'|'started'|'blocked'|'not_dispatched'|'unknown'|'interrupted'|'recovery_required';
type Reservation={dispatch:boolean;attemptId:string;status:ShowStatus};
export type SafeShow={attemptId?:string;status:ShowStatus;message:string;duplicate?:boolean};
export const messages:Record<ShowStatus,string>={requested:'Start aangevraagd.',registered:'Jullie zijn aangemeld. Wacht op de begeleider. Hij bepaalt wanneer jullie mogen lopen.',started:'De finaleshow is gestart. Blijf bij jullie groep en volg de aanwijzingen van de acteurs.',blocked:'De lokale showvoorwaarden staan de start nog niet toe. Vraag de begeleider.',not_dispatched:'De showcomputer is niet verbonden. Vraag de begeleider.',unknown:'Geen startbevestiging ontvangen. Vraag de begeleider om de regie te controleren.',interrupted:'De uitvoering is onderbroken. Vraag de regie om herstelcontrole.',recovery_required:'De showcomputer vraagt herstelcontrole. Vraag de regie.'};
function db(){const client=createPrivilegedClient();if(!client)throw new ApiError(503,'SHOW_UNAVAILABLE','De showkoppeling is tijdelijk niet beschikbaar. Vraag de begeleider.');return client.schema('api');}
function config(){const env=serverEnv();if(!env.DUINPAD_SHOW_API_BASE_URL||!env.DUINPAD_SHOW_API_TOKEN)return null;const origin=new URL(env.DUINPAD_SHOW_API_BASE_URL);if(origin.protocol!=='https:'||origin.pathname!=='/'||origin.username||origin.password||origin.search||origin.hash)throw new ApiError(503,'SHOW_UNAVAILABLE','De showverbinding is nog niet ingesteld.');return {origin:origin.origin,token:env.DUINPAD_SHOW_API_TOKEN};}
export function relayConfigured(){return Boolean(config());}
export function qrPayload(stage:'qr1'|'qr2',groupId:string,eventId:string=randomUUID(),issuedAt=Math.floor(Date.now()/1000)){
 if(!/^[A-Za-z0-9_-]{1,40}$/.test(groupId))throw new ApiError(409,'GROUP_UNAVAILABLE','De routegroep kan nog niet aan de show worden gekoppeld.');
 // Exact key order is shared with the bridge receipt hash; never insert PII labels.
 return {stage,group_id:groupId,event_id:eventId,issued_at:issuedAt,label:''};
}
export function payloadHash(payload:string){return createHash('sha256').update(payload,'utf8').digest('hex');}
async function reserve(input:{actorId:string;eventId:string;groupId:string;commandId:string;stage:'qr1'|'qr2';source:'actor'|'visitor';payload:string;hash:string;issuedAt:number}):Promise<Reservation>{
 const {data,error}=await db().rpc('duinpad_show_reserve',{_actor:input.actorId,_event:input.eventId,_run:input.groupId,_stage:input.stage,_id:input.commandId,_source:input.source,_payload:input.payload,_hash:input.hash,_issued_at:input.issuedAt});
 if(error)throw new ApiError(error.code==='42501'?403:409,'SHOW_NOT_ALLOWED','Deze showopdracht is nu niet toegestaan. Controleer de actuele stand.');return data;
}
export async function finishActorFinale(input:{attemptId:string;commandId?:string;status:Exclude<ShowStatus,'requested'|'registered'>;result:unknown;reconciled?:boolean}){await finish(input.attemptId,input.status,input.result,input.reconciled===true);}
export async function reserveActorFinale(input:{eventId:string;groupId:string;actorId:string;commandId:string;payloadHash:string;payload:object}){return reserve({...input,stage:'qr2',source:'actor',payload:JSON.stringify(input.payload),hash:input.payloadHash,issuedAt:(input.payload as {issued_at:number}).issued_at});}
async function finish(id:string,status:Exclude<ShowStatus,'requested'>,result:unknown,reconciled=false){const {error}=await db().rpc('duinpad_show_finish',{_id:id,_status:status,_result:result,_reconciled:reconciled});if(error)throw new ApiError(503,'SHOW_RECEIPT_UNAVAILABLE',messages.unknown);}
export function interpretRelay(status:number,body:unknown,stage:'qr1'|'qr2'):Omit<SafeShow,'attemptId'>{
 const b=typeof body==='object'&&body!==null?body as Record<string,unknown>:{};
 if(status===504||b.unknown===true)return {status:'unknown',message:messages.unknown};
 if(b.outcome==='interrupted'||b.outcome==='recovery_required')return {status:b.outcome,message:messages[b.outcome]};
 if(status>=200&&status<300&&b.ok===true){const s=stage==='qr1'?'registered':'started';return {status:s,message:messages[s],duplicate:b.duplicate===true};}
 if(status===503)return {status:'not_dispatched',message:messages.not_dispatched};
 if(b.ok===false&&status!==0){return {status:'blocked',message:typeof b.message==='string'&&b.message.length<=300?b.message:typeof b.error==='string'&&b.error.length<=300?b.error:messages.blocked};}
 return {status:'unknown',message:messages.unknown};
}
export async function requestVisitorShow(input:{actorId:string;eventId:string;runId:string;stage:'qr1'|'qr2';attemptId?:string;intentIssuedAt?:number;abortSignal?:AbortSignal}):Promise<SafeShow>{
 const cfg=config();if(!cfg)return {status:'not_dispatched',message:messages.not_dispatched};
 if(input.abortSignal?.aborted||input.intentIssuedAt!==undefined&&Date.now()/1000-input.intentIssuedAt>5)return {status:'not_dispatched',message:'De aanvraag is verlopen voordat deze verstuurd kon worden. Vraag de begeleider.'};
 const payload=qrPayload(input.stage,input.runId,input.attemptId,Math.floor(input.intentIssuedAt??Date.now()/1000)),body=JSON.stringify(payload);
 const slot=await reserve({actorId:input.actorId,eventId:input.eventId,groupId:input.runId,commandId:payload.event_id,stage:input.stage,source:'visitor',payload:body,hash:payloadHash(body),issuedAt:payload.issued_at});
 if(!slot.dispatch)return {attemptId:slot.attemptId,status:slot.status,message:messages[slot.status],duplicate:true};
 let result:Omit<SafeShow,'attemptId'>;
 // A slow reservation cannot turn an old click into a fresh command.
 if(input.abortSignal?.aborted||Date.now()/1000-payload.issued_at>5)result={status:'not_dispatched',message:'De aanvraag is verlopen voordat deze verstuurd kon worden. Vraag de begeleider.'};
 else try {const response=await fetch(cfg.origin+'/api/integration/qr',{method:'POST',headers:{Authorization:`Bearer ${cfg.token}`,'Content-Type':'application/json'},body,signal:input.abortSignal?AbortSignal.any([input.abortSignal,AbortSignal.timeout(15_000)]):AbortSignal.timeout(15_000),cache:'no-store',redirect:'error'});result=interpretRelay(response.status,await response.json().catch(()=>null),input.stage);}catch{result={status:'unknown',message:messages.unknown};}
 await finish(slot.attemptId,result.status as Exclude<ShowStatus,'requested'>,{ok:['started','registered'].includes(result.status),message:result.message});
 return {...result,attemptId:slot.attemptId};
}
export async function showReceipt(actorId:string,eventSlug:string,id?:string,reconcile=false,stage?:'qr1'|'qr2'):Promise<SafeShow|null>{
 const {data,error}=await db().rpc('duinpad_show_receipt',{_actor:actorId,_event_slug:eventSlug,_id:id??null,_stage:stage??null});
 if(error)throw new ApiError(403,'RECEIPT_UNAVAILABLE','Deze ontvangst is niet beschikbaar voor jouw account.');if(!data)return null;
 const row=data as {attemptId:string;runId:string;stage:'qr1'|'qr2';source:'visitor'|'actor';status:ShowStatus;payloadHash:string};
 // Actor receipts require their own current scoped grant; the actor module handles those.
 const cfg=config();if(reconcile&&cfg&&row.source==='visitor'&&['unknown','requested','interrupted','recovery_required'].includes(row.status)){
  const url=new URL('/api/integration/receipts/'+encodeURIComponent(row.attemptId),cfg.origin);url.search=new URLSearchParams({group_id:row.runId,payload_hash:row.payloadHash,kind:'qr'}).toString();
  try{const response=await fetch(url,{headers:{Authorization:`Bearer ${cfg.token}`},signal:AbortSignal.timeout(5_000),cache:'no-store',redirect:'error'});const body=await response.json();
   // Only a durable matching receipt proves an outcome; 404/offline never proves nonexecution.
   if(response.ok&&body.command_id===row.attemptId&&body.group_id===row.runId&&body.payload_hash===row.payloadHash&&body.found===true){
    const localGroup=body.group&&typeof body.group==='object'?body.group:{};
    const result=localGroup.recovery_required===true||localGroup.group_status==='interrupted'?{status:'recovery_required' as const,message:messages.recovery_required}:interpretRelay(200,body.result,row.stage);if(result.status!=='unknown'){await finish(row.attemptId,result.status as Exclude<ShowStatus,'requested'>,{ok:['started','registered'].includes(result.status),message:result.message},true);return {...result,attemptId:row.attemptId};}
   }
  }catch{/* A read failure leaves the durable uncertainty untouched. */}
 }
 return {attemptId:row.attemptId,status:row.status,message:messages[row.status]};
}
export async function showConnection(){const cfg=config();if(!cfg)return {configured:false,connected:false};try{const r=await fetch(cfg.origin+'/api/integration/group-status?group_id=connection-check',{headers:{Authorization:`Bearer ${cfg.token}`},signal:AbortSignal.timeout(3_000),cache:'no-store',redirect:'error'});const b=await r.json();return {configured:true,connected:r.ok&&b.connected===true};}catch{return {configured:true,connected:false};}}
