import { management } from './redesign-preflight.mjs';
import { assertFrightnightRelease, assertFrightnightSafety, FRIGHTNIGHT_SAFETY_SQL } from './frightnight-release.mjs';

const target=assertFrightnightRelease(process.env);
if(!process.env.FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID||!process.env.SUPABASE_SERVICE_ROLE_KEY)throw new Error('EXPLICIT_VERIFIED_INITIALIZATION_ACTOR_REQUIRED');
const safety=await management('/database/query',{read_only:true,query:FRIGHTNIGHT_SAFETY_SQL});
assertFrightnightSafety(safety[0]?.frightnight_safety);
const preservationQuery=`select jsonb_build_object(
 'authUsers',(select count(*) from auth.users),
 'households',(select count(*) from app_private.households),
 'legacyPayments',(select count(*) from app_private.payment_requests),
 'legacyOutbox',(select count(*) from app_private.email_outbox),
 'oldEvent',(select md5(to_jsonb(e)::text) from app_private.events e where slug='duindorp-halloween-2026')
) as preserved`;
const before=await management('/database/query',{read_only:true,query:preservationQuery});
const response=await fetch(`https://${target.projectRef}.supabase.co/rest/v1/rpc/frightnight_initialize`,{
 method:'POST',headers:{apikey:process.env.SUPABASE_SERVICE_ROLE_KEY,Authorization:`Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}`,'Content-Type':'application/json','Content-Profile':'api'},
 body:JSON.stringify({p_slug:target.slug,p_actor:process.env.FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID,p_confirmation:`${target.projectRef}:staging:duindorphalloweenstg`}),signal:AbortSignal.timeout(20000),
});
if(!response.ok)throw new Error(`FRIGHTNIGHT_INITIALIZE_REJECTED_${response.status}`);
const result=await response.json();
if(result.slug!==target.slug||result.mailMode!=='sink'||result.externalDelivery!==false||result.seedVersion<1)throw new Error('FRIGHTNIGHT_INITIALIZATION_PROOF_MISSING');
const after=await management('/database/query',{read_only:true,query:preservationQuery});
if(JSON.stringify(before[0]?.preserved)!==JSON.stringify(after[0]?.preserved))throw new Error('FRIGHTNIGHT_INITIALIZATION_CHANGED_LEGACY_DATA');
const finalSafety=await management('/database/query',{read_only:true,query:FRIGHTNIGHT_SAFETY_SQL});assertFrightnightSafety(finalSafety[0]?.frightnight_safety);
console.log(JSON.stringify({frightnightInitialized:true,seeded:result.seeded,seedVersion:result.seedVersion,ownerlessSyntheticOnly:true,legacyDataPreserved:true,mailMode:'sink',externalDelivery:false,syntheticWalkingFixture:true,jwtImpersonation:false}));
