import { NextResponse } from 'next/server';
import { z } from 'zod';
import { apiFailure, ApiError, assertTrustedOrigin, correlationId } from '@/lib/http/api';
import { readBoundedJson } from '@/lib/http/bounded-json';
import { authenticatedClient } from '@/lib/redesign/server';
import { checkpointPanel, checkpointPoster, safePanel } from '@/lib/duinpad/checkpoints';
import { requestVisitorShow, showConnection, showReceipt, messages } from '@/lib/duinpad/show';
import { serverEnv } from '@/lib/config/server-env';
import { gateArrivalUrl } from '@/lib/redesign/gate-credentials';
import { createGatePosterPdf } from '@/lib/redesign/pdf-writer';
export const dynamic='force-dynamic';export const runtime='nodejs';
type Context={params:Promise<{action:string}>};
const headers={'Cache-Control':'private, no-store','X-Robots-Tag':'noindex, nofollow',Vary:'Cookie'};
const output=(data:unknown)=>NextResponse.json(data,{headers});
function failure(error:{code?:string;message:string}){if(error.message==='RATE_LIMITED')throw new ApiError(429,'RATE_LIMITED','Wacht even voordat je opnieuw een code controleert.');if(error.code==='42501'||error.message==='NOT_AUTHORIZED')throw new ApiError(403,'NOT_AUTHORIZED','Deze actie is niet toegestaan voor jouw account.');throw new ApiError(409,'DUINPAD_UNAVAILABLE',error.message==='EVENING_ENDED'?'Jullie avond is afgelopen. Bekijk jullie herinneringen.':'Deze stap is gewijzigd of de code hoort niet bij jullie vrijgegeven bestemming. Vernieuw de actuele stand.');}
const credential=z.object({credential:z.string().regex(/^[A-Za-z0-9_-]{4,160}$/),portalId:z.uuid().optional(),method:z.enum(['qr','short_code']).default('qr')}).strict();
export async function GET(request:Request,context:Context){try{
 const {action}=await context.params,url=new URL(request.url);
 if(action==='admin')return output({...safePanel(await checkpointPanel()),show:await showConnection()});
 if(action==='poster'){
  const stage=z.enum(['qr1','qr2']).parse(url.searchParams.get('stage')),material=await checkpointPoster(stage);
  if(url.searchParams.get('format')!=='pdf')return output(material);
  const mode=z.enum(['mono','colour']).parse(url.searchParams.get('mode')??'mono');
  const bytes=createGatePosterPdf({gateName:material.label,gateCode:stage.toUpperCase(),shortCode:material.shortCode,arrivalUrl:gateArrivalUrl({id:material.id},material.credential,material.origin),eventDate:material.eventDate,revision:material.credentialRevision,duinpadStage:stage,instruction:material.instruction},mode);
  return new NextResponse(new Uint8Array(bytes),{headers:{...headers,'Content-Type':'application/pdf','Content-Disposition':`${url.searchParams.get('print')==='true'?'inline':'attachment'}; filename="Duinpad-${stage.toUpperCase()}-${mode}.pdf"`}});
 }
 const {client,actor}=await authenticatedClient();
 if(action==='snapshot'){const {data,error}=await client.schema('api').rpc('duinpad_finale_snapshot',{_event_slug:serverEnv().EVENT_SLUG});if(error)failure(error);return output({...data,show:await showReceipt(actor,serverEnv().EVENT_SLUG,undefined,false,data.recorded?'qr2':undefined)});}
 if(action==='receipt')return output(await showReceipt(actor,serverEnv().EVENT_SLUG,url.searchParams.has('id')?z.uuid().parse(url.searchParams.get('id')):undefined,true,url.searchParams.has('stage')?z.enum(['qr1','qr2']).parse(url.searchParams.get('stage')):undefined));
 throw new ApiError(404,'NOT_FOUND','Niet gevonden.');
}catch(error){return apiFailure(error,correlationId(request));}}
export async function POST(request:Request,context:Context){try{
 const intentIssuedAt=Date.now()/1000;assertTrustedOrigin(request);const {action}=await context.params,input=await readBoundedJson(request,4096);
 if(action==='checkpoint'){
  const data=z.discriminatedUnion('action',[z.object({action:z.literal('create'),label:z.string().trim().min(1).max(70),instruction:z.string().trim().min(1).max(500)}).strict(),z.object({action:z.literal('link'),portalId:z.uuid(),label:z.string().trim().min(1).max(70),instruction:z.string().trim().min(1).max(500)}).strict(),z.object({action:z.literal('rotate'),version:z.number().int().positive(),confirmRotation:z.literal(true)}).strict()]).parse(input);return output(safePanel(await checkpointPanel(data.action,data)));
 }
 const {client,actor}=await authenticatedClient(),slug=serverEnv().EVENT_SLUG;
 if(action==='validate'||action==='confirm'){
  const parsed=action==='validate'?credential.parse(input):credential.extend({choices:z.record(z.string(),z.enum(['visited','skipped'])),idempotencyKey:z.uuid(),confirm:z.literal(true)}).parse(input);
  const qr1=await client.schema('api').rpc('duinpad_checkpoint_validate',{_event_slug:slug,_credential:parsed.credential,_portal_id:parsed.portalId??null});if(qr1.error)failure(qr1.error);
  if(qr1.data){if(action==='validate')return output(qr1.data);const show=await requestVisitorShow({actorId:actor,eventId:qr1.data.eventId,runId:qr1.data.runId,stage:'qr1',attemptId:z.object({idempotencyKey:z.uuid()}).parse(input).idempotencyKey,intentIssuedAt,abortSignal:request.signal});return output({...qr1.data,show});}
  const args={_event_slug:slug,_credential:parsed.credential,_portal_id:parsed.portalId??null,_method:parsed.method};
  if(action==='validate'){const {data,error}=await client.schema('api').rpc('duinpad_finale_validate',args);if(error)failure(error);return output({...data,stage:'qr2'});}
  const p=credential.extend({choices:z.record(z.string(),z.enum(['visited','skipped'])),idempotencyKey:z.uuid(),confirm:z.literal(true)}).parse(input);
  const {data,error}=await client.schema('api').rpc('duinpad_finale_confirm',{...args,_participant_choices:p.choices,_idempotency_key:p.idempotencyKey});if(error)failure(error);
  let show=null;if(data.duplicate!==true)try{show=await requestVisitorShow({actorId:actor,eventId:data.eventId,runId:data.runId,stage:'qr2',attemptId:p.idempotencyKey,intentIssuedAt,abortSignal:request.signal});}catch{show={status:'unknown',message:messages.unknown};}
  else show=await showReceipt(actor,slug,undefined,false,'qr2');
  return output({...data,stage:'qr2',show});
 }
 if(action==='retry'){
  const retry=z.object({confirm:z.literal(true),idempotencyKey:z.uuid()}).strict().parse(input);const {data,error}=await client.schema('api').rpc('duinpad_finale_snapshot',{_event_slug:slug});if(error)failure(error);
  const previous=await showReceipt(actor,slug,undefined,false,'qr2');if(data.eveningEnded||!data.recorded||previous&&!['blocked','not_dispatched'].includes(previous.status))throw new ApiError(409,'SHOW_RECOVERY_REQUIRED','Laat de regie eerst de bestaande poging controleren.');
  return output(await requestVisitorShow({actorId:actor,eventId:data.eventId,runId:data.runId,stage:'qr2',attemptId:retry.idempotencyKey,intentIssuedAt,abortSignal:request.signal}));
 }
 throw new ApiError(404,'NOT_FOUND','Niet gevonden.');
}catch(error){return apiFailure(error,correlationId(request));}}
