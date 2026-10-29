// Real independent local Auth/PostgREST transactions. Never sends a message.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import { requireLocalTogetherDatabase, sql } from './together-fixtures.mjs';

requireLocalTogetherDatabase();
const url=process.env.NEXT_PUBLIC_SUPABASE_URL;
const key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY??process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const secret=process.env.SUPABASE_SECRET_KEY??process.env.SUPABASE_SERVICE_ROLE_KEY;
if(!url||!key||!secret)throw new Error('LOCAL_ACTIVATION_AUTH_REQUIRED');
const options={auth:{persistSession:false,autoRefreshToken:false}};
const privileged=createClient(url,secret,options);
const event='duindorp-halloween-2026';
const literal=value=>"'"+value.replaceAll("'","''")+"'";
const admin=createClient(url,key,options);
assert.equal((await admin.auth.signInWithPassword({email:'admin@example.invalid',password:'local-test-only'})).error,null);
async function rpc(client,name,args){const result=await client.schema('api').rpc(name,args);assert.equal(result.error,null,`${name}: ${result.error?.message}`);return result.data;}
const choices=await rpc(admin,'admin_registration_creation_options',{_event_slug:event});
const channelBefore=sql(`select settings->>'groupRegistrationOpen' from app_private.events where slug=${literal(event)}`);
const reason='Synthetic isolated registration activation concurrency fixture';
function payload(email){return{parentName:'Synthetic invited parent',email,phone:'0612345678',preferredStartAt:choices.allowedStartTimes[0],desiredEndAt:choices.allowedEndTimes.at(-1),children:[{name:'Synthetic first child',age:6},{name:'Synthetic second child',age:8},{name:'Synthetic third child',age:10}]};}
function createArgs(email,command=randomUUID()){return{_event_slug:event,_payload:payload(email),_expected_event_version:choices.eventVersion,_command_id:command,_reason:reason};}
async function account(email){const password=randomUUID();const created=await privileged.auth.admin.createUser({email,password,email_confirm:true});assert.equal(created.error,null);return{email,password,user:created.data.user};}
async function login(identity){const client=createClient(url,key,options);assert.equal((await client.auth.signInWithPassword({email:identity.email,password:identity.password})).error,null);return client;}
const token=registration=>sql(`select app_private.registration_activation_token(${literal(registration)}::uuid)`);
const children=registration=>sql(`select jsonb_agg(child_id order by child_id)::text from app_private.registration_children where registration_id=${literal(registration)}::uuid`);
const outboxCount=registration=>Number(sql(`select count(*) from app_private.email_outbox where payload->>'registrationId'=${literal(registration)}`));

// A real old login cannot become fresh through refresh or account age.
const parentIdentity=await account(`activation-race-${randomUUID()}@example.invalid`);
const oldLogin=await login(parentIdentity);
const create=createArgs(parentIdentity.email);
const simultaneousCreates=await Promise.all(Array.from({length:6},()=>admin.schema('api').rpc('admin_registration_create',create)));
assert.ok(simultaneousCreates.every(result=>!result.error));
const created=simultaneousCreates[0].data;
for(const result of simultaneousCreates)assert.deepEqual(result.data,created);
assert.equal(created.existing,false);
const registration=created.registrationId,originalChildren=children(registration),firstToken=token(registration);
assert.equal(JSON.parse(originalChildren).length,3);
assert.equal(outboxCount(registration),1);
assert.equal(sql(`select count(*) from app_private.household_members m join app_private.registrations r on r.household_id=m.household_id where r.id=${literal(registration)}::uuid`),'0');
const duplicates=await Promise.all(Array.from({length:3},()=>rpc(admin,'admin_registration_create',createArgs(parentIdentity.email))));
assert.ok(duplicates.every(result=>result.existing&&result.registrationId===registration));
const oldAttempt=await oldLogin.schema('api').rpc('registration_activation_claim',{_token:firstToken,_command_id:randomUUID(),_mode:'fresh'});
assert.equal(oldAttempt.error?.message,'FRESH_LOGIN_OR_EXPLICIT_CLAIM_REQUIRED');
const freshLogin=await login(parentIdentity),claim={_token:firstToken,_command_id:randomUUID(),_mode:'fresh'};
const callbacks=await Promise.all(Array.from({length:6},()=>freshLogin.schema('api').rpc('registration_activation_claim',claim)));
assert.ok(callbacks.every(result=>!result.error&&result.data.activated));
for(const result of callbacks)assert.deepEqual(result.data,callbacks[0].data);
assert.equal(children(registration),originalChildren);
assert.equal(outboxCount(registration),1);
assert.equal(sql(`select count(*) from app_private.audit_events where action='registration.activated' and resource_id=${literal(registration)}::uuid`),'1');
assert.equal(sql(`select count(*) from app_private.household_members m join app_private.registrations r on r.household_id=m.household_id where r.id=${literal(registration)}::uuid and m.user_id=${literal(parentIdentity.user.id)}::uuid and m.revoked_at is null`),'1');

// Repeated invitation commands commit once; different concurrent commands must
// serialize on the registration version instead of producing two live links.
const pending=await rpc(admin,'admin_registration_create',createArgs(`activation-resend-${randomUUID()}@example.invalid`));
const pendingChildren=children(pending.registrationId),oldToken=token(pending.registrationId);
const invite={_event_slug:event,_registration_id:pending.registrationId,_expected_registration_version:pending.version,_email:null,_command_id:randomUUID(),_reason:reason};
const resends=await Promise.all(Array.from({length:6},()=>admin.schema('api').rpc('admin_registration_invite',invite)));
assert.ok(resends.every(result=>!result.error));
for(const result of resends)assert.deepEqual(result.data,resends[0].data);
assert.equal(outboxCount(pending.registrationId),2);
assert.notEqual(token(pending.registrationId),oldToken);
const competing=await Promise.all(Array.from({length:2},()=>admin.schema('api').rpc('admin_registration_invite',{...invite,_expected_registration_version:resends[0].data.version,_command_id:randomUUID()})));
assert.equal(competing.filter(result=>!result.error).length,1);
assert.equal(competing.filter(result=>result.error?.message==='STALE_VERSION').length,1);
assert.equal(outboxCount(pending.registrationId),3);
assert.equal(children(pending.registrationId),pendingChildren);
assert.equal(sql(`select count(*) from app_private.email_outbox where payload->>'registrationId'=${literal(pending.registrationId)} and status='pending'`),'1');

// Correcting an invitation and claiming its old reference race on the same
// event/registration lock. Either the verified claim or the correction wins.
const raceIdentity=await account(`activation-correction-${randomUUID()}@example.invalid`);
const raceRegistration=await rpc(admin,'admin_registration_create',createArgs(raceIdentity.email));
const raceChildren=children(raceRegistration.registrationId),raceToken=token(raceRegistration.registrationId),raceLogin=await login(raceIdentity);
const correctedEmail=`activation-corrected-${randomUUID()}@example.invalid`;
const [corrected,claimed]=await Promise.all([
 admin.schema('api').rpc('admin_registration_invite',{_event_slug:event,_registration_id:raceRegistration.registrationId,_expected_registration_version:raceRegistration.version,_email:correctedEmail,_command_id:randomUUID(),_reason:reason}),
 raceLogin.schema('api').rpc('registration_activation_claim',{_token:raceToken,_command_id:randomUUID(),_mode:'fresh'}),
]);
assert.equal([corrected,claimed].filter(result=>!result.error).length,1);
if(!corrected.error){
 assert.equal(claimed.error?.message,'INVITATION_UNAVAILABLE');
 assert.equal(sql(`select count(*) from app_private.household_members m join app_private.registrations r on r.household_id=m.household_id where r.id=${literal(raceRegistration.registrationId)}::uuid`),'0');
 assert.equal(outboxCount(raceRegistration.registrationId),2);
}else{
 assert.equal(corrected.error.message,'PENDING_ACTIVATION_REQUIRED');
 assert.equal(claimed.data.activated,true);
 assert.equal(outboxCount(raceRegistration.registrationId),1);
}
assert.equal(children(raceRegistration.registrationId),raceChildren);
assert.equal(sql(`select settings->>'groupRegistrationOpen' from app_private.events where slug=${literal(event)}`),channelBefore);
console.log(JSON.stringify({code:'REGISTRATION_ACTIVATION_CONCURRENCY_VERIFIED',createWriters:6,claimCallbacks:6,resendWriters:6,versionCompetitors:2,claimCorrectionRace:true,stableChildren:true,oneActivation:true,publicChannelUnchanged:true,noExternalDeliveries:true}));
