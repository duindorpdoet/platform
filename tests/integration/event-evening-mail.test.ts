import {execFileSync,spawn}from 'node:child_process';
import {readFileSync}from 'node:fs';
import {afterAll,beforeAll,describe,expect,it,vi}from 'vitest';
import {Webhook as HookVerifier}from 'standardwebhooks';
vi.mock('server-only',()=>({}));
const state=vi.hoisted(()=>({rpc:vi.fn(),recipients:new Set(['evening-family@example.invalid','other-evening-family@example.invalid','owner@example.invalid']),env:{APP_ENVIRONMENT:'staging',EVENT_SLUG:'duindorp-halloween-2026',EVENT_EVENING_BATCH_SIZE:1,CRON_SECRET:'local-event-evening-cron',MAIL_MODE:'allowlist',NEWSLETTER_SENDING_ENABLED:'false',NEXT_PUBLIC_SUPABASE_URL:'https://fixture.supabase.co',SEND_EMAIL_HOOK_SECRET:`v1,whsec_${Buffer.alloc(32,3).toString('base64')}`,APP_URL:'https://evening.example.invalid',MAIL_IDENTITY_SECRET:'local-independent-evening-mail-identity-secret'}}));
vi.mock('@/lib/config/server-env',()=>({serverEnv:()=>state.env,mailAllowlist:()=>state.recipients}));
vi.mock('@/lib/supabase/privileged',()=>({createPrivilegedClient:()=>({schema:()=>({rpc:state.rpc})})}));
vi.mock('@/lib/editorial/worker',()=>({editorialTick:async()=>{}}));
vi.mock('@/lib/pwa/portal-push',()=>({deliverPortalPushBatch:async()=>{}}));
vi.mock('@/lib/social-share/cleanup',()=>({cleanupSocialShareAssets:async()=>{}}));
import {POST as worker}from '@/app/api/jobs/mail/route';
import {handleMail}from '@/supabase/functions/send-email-hook/handler';
import type {Rpc}from '@/supabase/functions/send-email-hook/store';
import type {ResendMessage}from '@/supabase/functions/send-email-hook/resend';

// Deliberately fixed: no caller-provided connection string/container/database.
// The container has --network none; the provider below is an in-process fake.
const enabled=process.env.EVENT_EVENING_MAIL_INTEGRATION==='1';
const container='supabase_db_duindorp_event_close_20261101',database='portal_impact_mail_integration_crew';
const literal=(value:unknown)=>value===null||value===undefined?'null':typeof value==='number'||typeof value==='boolean'?String(value):"'"+(typeof value==='string'?value:JSON.stringify(value)).replaceAll("'","''")+"'";
function sql(query:string){
 if(!enabled)throw new Error('EXPLICIT_LOCAL_EVENT_EVENING_INTEGRATION_REQUIRED');
 return execFileSync('docker',['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1'],{input:query,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim();
}
function sqlAsync(query:string):Promise<string>{
 if(!enabled)throw new Error('EXPLICIT_LOCAL_EVENT_EVENING_INTEGRATION_REQUIRED');
 return new Promise((resolve,reject)=>{
  const child=spawn('docker',['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1']);let output='';
  child.stdout.on('data',chunk=>{output+=chunk.toString();});child.stderr.resume();child.on('error',()=>reject(new Error('LOCAL_EVENING_RPC_UNAVAILABLE')));child.on('close',code=>code===0?resolve(output.trim()):reject(new Error('LOCAL_EVENING_RPC_FAILED')));child.stdin.end(query);
 });
}
async function rpc(name:string,args:Record<string,unknown>){
 if(!/^[a-z][a-z0-9_]*$/.test(name)||Object.keys(args).some(key=>!/^_[a-z_]+$/.test(key)))throw new Error('INVALID_LOCAL_EVENING_RPC');
 const call=`api.${name}(${Object.entries(args).map(([key,value])=>`${key}=>${literal(value)}`).join(',')})`;
 const query=name==='worker_claim_outbox'?`select coalesce(jsonb_agg(to_jsonb(r)),'[]')from ${call} r;`:`select to_jsonb(${call});`;
 return JSON.parse(await sqlAsync(`begin;set local role service_role;${query}commit;`)||'null');
}
const actor=(id:string)=>`select set_config('request.jwt.claims',${literal(JSON.stringify({sub:id,role:'authenticated'}))},false);`;
const admin='f0000000-0000-0000-0000-000000000001',family='f6100000-0000-4000-8000-000000000001',otherFamily='f6100000-0000-4000-8000-000000000002',resident='e0000000-0000-0000-0000-000000000001';
const runWorker=()=>worker(new Request('https://evening.example.invalid/api/jobs/mail',{method:'POST',headers:{authorization:'Bearer local-event-evening-cron'},body:'{}'}));
const json=<T>(query:string)=>JSON.parse(sql(query))as T;
const lastJson=<T>(query:string)=>JSON.parse(sql(query).split('\n').at(-1)!)as T;

describe.skipIf(!enabled)('isolated PostgreSQL evening closure and house thanks -> real Node worker/render -> signed gateway -> fake idempotent provider',()=>{
 const providerRecords=new Map<string,{id:string;message:ResendMessage}>();
 const calls:Array<{key:string;outboxId:string;type:string;message:ResendMessage}>=[];
 let loseNextHouseAcknowledgement=true,rejectNextHouse=false,loseNextCertificateAcknowledgement=true;
 beforeAll(()=>{
  expect(execFileSync('docker',['inspect','--format','{{.HostConfig.NetworkMode}}',container],{encoding:'utf8'}).trim()).toBe('none');
  expect(sql("select current_database()||':'||current_setting('cron.launch_active_jobs');")).toBe(database+':off');
  sql(readFileSync('tests/integration/fixtures/event-evening-mail.sql','utf8'));
  sql("select api.worker_mail_bootstrap('staging','sender@example.invalid','De Poorten','reply@example.invalid');"+actor(admin)+"select api.mail_admin_command('staging','f0000000-0000-0000-0000-000000000001','duindorp-halloween-2026','save',0,null,'{\"provider\":\"resend\",\"fromEmail\":\"sender@example.invalid\",\"fromName\":\"De Poorten\",\"replyTo\":\"reply@example.invalid\"}');update app_private.mail_config_heads set active_id=draft_id,draft_id=null where environment='staging';");
  vi.stubEnv('APP_URL',state.env.APP_URL);
  state.rpc.mockImplementation(async(name:string,args:Record<string,unknown>)=>{
   try{return{data:await rpc(name,args),error:null};}catch{return{data:null,error:{code:'LOCAL_EVENING_RPC_FAILED'}};}
  });
  const fakeProvider=vi.fn(async(url:RequestInfo|URL,init?:RequestInit)=>{
   expect(String(url)).toBe('https://api.resend.com/emails');
   const key=new Headers(init?.headers).get('Idempotency-Key')!;expect(key).toMatch(/^mail\/[0-9a-f-]{36}\/1$/);
   const message=JSON.parse(String(init?.body))as ResendMessage;
   const type=message.tags.find(item=>item.name==='message_type')!.value,outboxId=message.tags.find(item=>item.name==='outbox_id')!.value;
   expect(message.to).toHaveLength(1);expect(state.recipients.has(message.to[0])).toBe(true);
   calls.push({key,type,outboxId,message});
   if(type==='house_thanks_received'&&rejectNextHouse){rejectNextHouse=false;return Response.json({message:'SYNTHETIC_CONCLUSIVE_REJECTION'},{status:400});}
   const previous=providerRecords.get(key);if(previous){expect(message).toEqual(previous.message);return Response.json({id:previous.id});}
   const saved={id:crypto.randomUUID(),message};providerRecords.set(key,saved);
   // Simulate provider acceptance followed by a lost acknowledgement. No network
   // request is sent; the next attempt must reuse this exact durable identity.
   if(type==='house_thanks_received'&&loseNextHouseAcknowledgement){loseNextHouseAcknowledgement=false;throw new Error('SYNTHETIC_PROVIDER_ACK_LOST');}
   if(type==='portal_certificate_ready'&&loseNextCertificateAcknowledgement){loseNextCertificateAcknowledgement=false;throw new Error('SYNTHETIC_CERTIFICATE_ACK_LOST');}
   return Response.json({id:saved.id});
  });
  vi.stubGlobal('fetch',async(url:RequestInfo|URL,init?:RequestInit)=>{
   expect(String(url)).toBe('https://fixture.supabase.co/functions/v1/send-email-hook');
   return handleMail(new Request(String(url),init),{
    env:name=>({...state.env,RESEND_API_KEY:'local-test-only',MAIL_ALLOWED_RECIPIENTS:[...state.recipients].join(',')}as Record<string,unknown>)[name]as string|undefined,
    verify:(body,headers)=>new HookVerifier(state.env.SEND_EMAIL_HOOK_SECRET.replace(/^v1,whsec_/,'' )).verify(body,Object.fromEntries(headers),{jsonParse:true}),rpc:rpc as Rpc,fetcher:fakeProvider,
   });
  });
 });
 afterAll(()=>{vi.unstubAllGlobals();vi.unstubAllEnvs();});
 it('keeps definitive organization copy and stored house receipts through provider uncertainty without duplicate logical mail',async()=>{
  const subject='Lokaal aangepast organisatiebedankje 🎃',body='Beste Duindorpers,\n\nEen eigen organisatoralinea.\n<script>Dit blijft tekst</script>';
  const snapshot=lastJson<{counts:{participantAccounts:number;participatingHouses:number}}>(actor(admin)+`select api.event_closure_confirm('duindorp-halloween-2026',${literal(subject)},${literal(body)},'f6500000-0000-4000-8000-000000000001');`);
  expect(snapshot.counts).toMatchObject({participantAccounts:2,participatingHouses:2});
  expect(sql("select count(*)from app_private.email_outbox where message_type in('event_closure_thanks','house_thanks_received');")).toBe('0');
  const allMessage='Bedankt aan alle huizen!\n<b>Dit blijft ook tekst</b>';
  sql(actor(family)+`select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,${literal(allMessage)},'f6600000-0000-4000-8000-000000000001');`);
  expect(sql('select count(*)from app_private.event_house_thanks_targets where processed_at is null;')).toBe('2');
  expect((await runWorker()).status).toBe(200);
  expect(sql('select count(*)from app_private.event_house_thanks_receipts;')).toBe('1');
  expect(sql('select count(*)from app_private.event_house_thanks_targets where processed_at is null;')).toBe('1');
  const campaign=calls.find(item=>item.type==='event_closure_thanks')!;expect(campaign.message.subject).toBe(subject);expect(campaign.message.text).toContain(body);expect(campaign.message.html).toContain('&lt;script&gt;Dit blijft tekst&lt;/script&gt;');expect(campaign.message.html).not.toContain('<script>');
  const uncertain=json<{id:string;status:string}>('select jsonb_build_object(\'id\',id,\'status\',status)from app_private.email_outbox where message_type=\'house_thanks_received\';');
  expect(uncertain.status).toBe('unknown');expect(sql(`select status from app_private.mail_envelopes where outbox_id=${literal(uncertain.id)};`)).toBe('unknown');
  const inbox=lastJson<{total:number;messages:Array<{message:string;mailCounts:Record<string,number>}>}>(actor(resident)+"select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001');");
  expect(inbox.total).toBe(1);expect(inbox.messages[0]).toMatchObject({message:allMessage,mailCounts:{unknown:1}});
  expect((await runWorker()).status).toBe(200);
  expect(sql('select count(*)from app_private.event_house_thanks_receipts;')).toBe('2');
  // Make only this synthetic retry due, representing elapsed durable backoff.
  sql(`update app_private.email_outbox set next_attempt_at=clock_timestamp()where id=${literal(uncertain.id)};`);
  await runWorker();
  const retryCalls=calls.filter(item=>item.outboxId===uncertain.id);expect(retryCalls).toHaveLength(2);expect(retryCalls[0].key).toBe(retryCalls[1].key);expect(retryCalls[0].message).toEqual(retryCalls[1].message);
  expect(providerRecords.size).toBe(4);expect(calls).toHaveLength(5);
  expect(sql("select count(*)from app_private.email_outbox where message_type in('event_closure_thanks','house_thanks_received')and status='accepted';")).toBe('4');
  const before=calls.length;await Promise.all([runWorker(),runWorker()]);expect(calls).toHaveLength(before);
  sql(actor(family)+`select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,${literal(allMessage)},'f6600000-0000-4000-8000-000000000001');`);
  await runWorker();expect(calls).toHaveLength(before);expect(sql('select count(*)from app_private.event_house_thanks_receipts;')).toBe('2');
 },30000);
 it('leaves an expired uncertain personal thank visible and reconcilable without blindly sending again',async()=>{
  loseNextHouseAcknowledgement=true;
  sql(actor(family)+"select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000001','welcome','Een extra persoonlijk lokaal bedankje','f6600000-0000-4000-8000-000000000002');");
  await runWorker();
  const personal=json<{id:string;status:string}>("select jsonb_build_object('id',o.id,'status',o.status)from app_private.email_outbox o join app_private.event_house_thanks_mail_recipients m on m.outbox_id=o.id join app_private.event_house_thanks_receipts r on r.id=m.receipt_id join app_private.event_house_thanks s on s.id=r.submission_id where s.kind='personal';");
  expect(personal.status).toBe('unknown');const attempts=calls.filter(item=>item.outboxId===personal.id).length;
  sql(`update app_private.mail_envelopes set first_attempt_at=clock_timestamp()-interval '24 hours'where outbox_id=${literal(personal.id)};`);
  const before=calls.length;await runWorker();await runWorker();expect(calls).toHaveLength(before);expect(calls.filter(item=>item.outboxId===personal.id)).toHaveLength(attempts);
  expect(sql(`select status from app_private.mail_envelopes where outbox_id=${literal(personal.id)};`)).toBe('reconcile');expect(sql(`select status from app_private.email_outbox where id=${literal(personal.id)};`)).toBe('unknown');
  const inbox=lastJson<{total:number;messages:Array<{kind:string;message:string;mailCounts:Record<string,number>}>}>(actor(resident)+"select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001');");
  expect(inbox.total).toBe(2);expect(inbox.messages.find(item=>item.kind==='personal')).toMatchObject({message:'Een extra persoonlijk lokaal bedankje',mailCounts:{unknown:1}});
  const result=lastJson<{houseRequeued:number}>(actor(admin)+"select api.event_closure_retry_failed('duindorp-halloween-2026');");expect(result.houseRequeued).toBe(0);await runWorker();expect(calls).toHaveLength(before);
 },30000);
 it('recovers a conclusive failed house mail through the organizer action using the same outbox and provider identity',async()=>{
  rejectNextHouse=true;
  sql(actor(family)+"select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000002','beautiful','Een lokaal veilig herstelbaar bedankje','f6600000-0000-4000-8000-000000000003');");
  await runWorker();
  const failed=json<{id:string;status:string}>("select jsonb_build_object('id',o.id,'status',o.status)from app_private.email_outbox o join app_private.event_house_thanks_mail_recipients m on m.outbox_id=o.id join app_private.event_house_thanks_receipts r on r.id=m.receipt_id join app_private.event_house_thanks s on s.id=r.submission_id where s.kind='personal'and s.portal_id='12000000-0000-0000-0000-000000000002';");
  expect(failed.status).toBe('failed');
  const inbox=lastJson<{messages:Array<{kind:string;mailCounts:Record<string,number>}>}>(actor(resident)+"select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000002');");
  expect(inbox.messages.find(item=>item.kind==='personal')?.mailCounts).toEqual({failed:1});
  const adminSnapshot=lastJson<{mail:{houseFailed:number}}>(actor(admin)+"select api.event_closure_admin_snapshot('duindorp-halloween-2026');");expect(adminSnapshot.mail.houseFailed).toBe(1);
  const first=calls.find(item=>item.outboxId===failed.id)!;expect(providerRecords.has(first.key)).toBe(false);
  const retry=lastJson<{houseRequeued:number;requeued:number}>(actor(admin)+"select api.event_closure_retry_failed('duindorp-halloween-2026');");expect(retry).toMatchObject({houseRequeued:1,requeued:1});
  // Only this synthetic retry becomes due; no global clock/timeouts are changed.
  sql(`update app_private.email_outbox set next_attempt_at=clock_timestamp()where id=${literal(failed.id)};`);
  await runWorker();
  const retries=calls.filter(item=>item.outboxId===failed.id);expect(retries).toHaveLength(2);expect(retries[0].key).toBe(retries[1].key);expect(retries[0].message).toEqual(retries[1].message);
  expect(sql(`select status from app_private.email_outbox where id=${literal(failed.id)};`)).toBe('accepted');expect(providerRecords.has(first.key)).toBe(true);
  const attempts=calls.length;await runWorker();expect(calls).toHaveLength(attempts);expect(calls).toHaveLength(8);expect(providerRecords.size).toBe(6);
 },30000);

 it('keeps standard reactions as counters, permits custom crew mail and preserves an unknown outcome after access becomes viewer',async()=>{
  const before=calls.length,standard='Bedankt voor jullie inzet en de mooie Halloweenavond! Dankzij jullie hebben we samen kunnen griezelen in Duindorp. 🎃';
  sql(`update app_private.portal_owners set role='crew'where portal_id='12000000-0000-0000-0000-000000000001'and user_id=${literal(otherFamily)};`);
  sql(actor(otherFamily)+`select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,${literal('\u00a0'+standard+'\ufeff')},'f6600000-0000-4000-8000-000000000004');select api.portal_thanks_closed_save('duindorp-halloween-2026','personal','12000000-0000-0000-0000-000000000001','treats',${literal('\u2003\n')},'f6600000-0000-4000-8000-000000000005');`);
  await runWorker();await runWorker();await runWorker();expect(calls).toHaveLength(before);
  const inbox=lastJson<{total:number;aggregateOnlyCount:number;customMessageCount:number;unread:number;messages:unknown[]}>(actor(resident)+"select api.portal_thanks_inbox('duindorp-halloween-2026','12000000-0000-0000-0000-000000000001');");
  expect(inbox).toMatchObject({total:4,aggregateOnlyCount:2,customMessageCount:2,unread:2});expect(inbox.messages).toHaveLength(2);
  expect(sql("select count(*)from app_private.email_outbox where message_type='house_thanks_received'and recipient_email='other-evening-family@example.invalid';")).toBe('0');
  // Pre-release queued standard payloads stay blocked. The explicit crew
  // authorization now permits the custom crew payload with its existing key.
  sql(`insert into app_private.email_outbox(id,dedupe_key,message_type,recipient_ref,recipient_email,payload)
   select 'f6700000-0000-4000-8000-000000000001','synthetic-old-default-job','house_thanks_received',r.id::text,'owner@example.invalid',jsonb_build_object('receiptId',r.id,'eventId',r.event_id,'portalId',r.portal_id,'portalName','Synthetic house','kind',s.kind,'message',s.message,'senderLabel','Een gezin uit Duindorp','portalRoomPath','/mijn-huis')from app_private.event_house_thanks_receipts r join app_private.event_house_thanks s on s.id=r.submission_id where s.household_id='f6200000-0000-4000-8000-000000000002'and s.kind='all'and r.portal_id='12000000-0000-0000-0000-000000000001';
   insert into app_private.event_house_thanks_mail_recipients(receipt_id,recipient_email,outbox_id)select recipient_ref::uuid,recipient_email,id from app_private.email_outbox where id='f6700000-0000-4000-8000-000000000001';
   insert into app_private.email_outbox(id,dedupe_key,message_type,recipient_ref,recipient_email,payload)
   select 'f6700000-0000-4000-8000-000000000002','synthetic-old-crew-job',message_type,recipient_ref,'other-evening-family@example.invalid',payload from app_private.email_outbox where message_type='house_thanks_received'and recipient_email='owner@example.invalid'and payload->>'kind'='all'and payload->>'portalId'='12000000-0000-0000-0000-000000000001'and dedupe_key<>'synthetic-old-default-job';
   insert into app_private.event_house_thanks_mail_recipients(receipt_id,recipient_email,outbox_id)select recipient_ref::uuid,recipient_email,id from app_private.email_outbox where id='f6700000-0000-4000-8000-000000000002';`);
  await runWorker();expect(calls).toHaveLength(before+1);
  expect(sql("select status from app_private.email_outbox where dedupe_key='synthetic-old-default-job';")).toBe('suppressed');
  expect(sql("select status from app_private.email_outbox where dedupe_key='synthetic-old-crew-job';")).toBe('accepted');
  expect(calls.at(-1)?.message.to).toEqual(['other-evening-family@example.invalid']);
  sql(actor(otherFamily)+"select api.portal_thanks_closed_save('duindorp-halloween-2026','all',null,null,'Later geschreven tekst','f6600000-0000-4000-8000-000000000006',(select id from app_private.event_house_thanks where household_id='f6200000-0000-4000-8000-000000000002'and kind='all'));select app_private.event_house_thanks_queue_mail(id)from app_private.event_house_thanks_receipts where submission_id=(select id from app_private.event_house_thanks where household_id='f6200000-0000-4000-8000-000000000002'and kind='all');");
  await runWorker();expect(calls).toHaveLength(before+1);expect(sql("select count(*)from app_private.email_outbox where message_type='house_thanks_received';")).toBe('6');
  // Transfer the primary role atomically; the former owner remains a viewer.
  sql(`begin;update app_private.portal_owners set role='viewer'where portal_id='12000000-0000-0000-0000-000000000001'and user_id=${literal(resident)};update app_private.portal_owners set role='owner'where portal_id='12000000-0000-0000-0000-000000000001'and user_id=${literal(otherFamily)};commit;`);
  await runWorker();expect(calls).toHaveLength(before+1);
  expect(sql("select o.status||':'||e.status from app_private.email_outbox o join app_private.mail_envelopes e on e.outbox_id=o.id where o.message_type='house_thanks_received'and o.payload->>'kind'='personal'and o.payload->>'portalId'='12000000-0000-0000-0000-000000000001';")).toBe('unknown:reconcile');
  expect(sql("select count(*)from app_private.email_outbox where message_type='event_closure_thanks'and status='accepted';")).toBe('2');
 },30000);

 it('only sends an explicitly confirmed certificate campaign once per event/address and preserves accepted/unknown delivery after access is revoked',async()=>{
  expect(sql("select count(*)from app_private.email_outbox where message_type='portal_certificate_ready';")).toBe('0');
  const before=calls.length;await runWorker();expect(calls).toHaveLength(before);
  expect(sql("select count(*)from app_private.email_outbox where message_type='portal_certificate_ready';")).toBe('0');
  // This crew account is eligible for two houses but receives one event mail.
  sql(`insert into app_private.portal_owners(portal_id,user_id,role)values('12000000-0000-0000-0000-000000000002',${literal(otherFamily)},'crew');`);
  const subject='Jullie eigen certificaat staat klaar 🎃',body='Beste poortteam,\n\nDank voor jullie decor en ontvangst.\n<script>Dit blijft gewone tekst</script>';
  sql(actor(admin)+`select api.portal_certificate_confirm('duindorp-halloween-2026',${literal(subject)},${literal(body)},'f6800000-0000-4000-8000-000000000001');`);
  await runWorker();await runWorker();
  const certificateCalls=calls.filter(item=>item.type==='portal_certificate_ready');expect(certificateCalls).toHaveLength(2);
  expect(new Set(certificateCalls.map(item=>item.message.to[0])).size).toBe(2);
  for(const item of certificateCalls){expect(item.message.subject).toBe(subject);expect(item.message.text).toContain(body);expect(item.message.html).toContain('&lt;script&gt;Dit blijft gewone tekst&lt;/script&gt;');expect(item.message.html).not.toContain('<script>');expect(item.message.html).toContain('https://evening.example.invalid/mijn-huis');}
  expect(sql("select count(*)from app_private.email_outbox where message_type='portal_certificate_ready';")).toBe('2');
  // The legacy claim reconciler can project a recent uncertain envelope as
  // deferred while retaining its provider identity. Read that authoritative
  // envelope rather than assuming its outbox projection has stayed unknown.
  const unknown=json<{id:string;email:string}>("select jsonb_build_object('id',o.id,'email',o.recipient_email)from app_private.email_outbox o join app_private.mail_envelopes e on e.outbox_id=o.id where o.message_type='portal_certificate_ready'and e.status='unknown';");
  const accepted=json<{id:string;email:string}>("select jsonb_build_object('id',id,'email',recipient_email)from app_private.email_outbox where message_type='portal_certificate_ready'and status='accepted';");
  expect(unknown.id).not.toBe(accepted.id);expect(providerRecords.has(`mail/${unknown.id}/1`)).toBe(true);
  // Hold only this synthetic provider retry until the access-change scenario;
  // otherwise its legitimate two-second backoff can elapse during assertions.
  sql(`update app_private.email_outbox set next_attempt_at=clock_timestamp()+interval'1 hour'where id=${literal(unknown.id)};`);
  const afterConfirmation=calls.length;
  sql(actor(admin)+`select api.portal_certificate_confirm('duindorp-halloween-2026',${literal(subject)},${literal(body)},'f6800000-0000-4000-8000-000000000001');`);
  await runWorker();expect(calls).toHaveLength(afterConfirmation);
  sql(`update app_private.portal_owners set suspended_at=now()where user_id in(select id from auth.users where lower(trim(email))in(${literal(unknown.email)},${literal(accepted.email)}));update app_private.email_outbox set next_attempt_at=clock_timestamp()where id=${literal(unknown.id)};`);
  await runWorker();expect(calls).toHaveLength(afterConfirmation);
  expect(sql(`select status from app_private.email_outbox where id=${literal(unknown.id)};`)).toBe('unknown');
  expect(sql(`select status from app_private.mail_envelopes where outbox_id=${literal(unknown.id)};`)).toBe('unknown');
  sql(`select api.worker_update_outbox_v2(${literal(accepted.id)},'suppressed',null,'PORTAL_CERTIFICATE_RECIPIENT_UNAVAILABLE',null);`);
  expect(sql(`select status from app_private.email_outbox where id=${literal(accepted.id)};`)).toBe('accepted');
  sql(actor(admin)+"select api.portal_certificate_retry_failed('duindorp-halloween-2026');");
  await runWorker();expect(calls).toHaveLength(afterConfirmation);
  expect(sql("select count(*)from app_private.email_outbox where message_type='portal_certificate_ready';")).toBe('2');
 },30000);

});
