// The isolated editor hotfix must preserve the currently deployed staging Auth
// policy. These are metadata GETs only: no OTP, webhook send or secret mutation.
import { createHash } from 'node:crypto';
import { appendFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { UPDATES_HTML_BRANCH } from './staging-installed-history.mjs';

const ref='nocteiuvohesvqbowchw';
const digest=value=>createHash('sha256').update(value).digest('hex');
export async function stagingAuthPolicy(env,request=fetch) {
  if(env.GITHUB_REPOSITORY!=='duindorpdoet/platform'||env.GITHUB_REF!==`refs/heads/${UPDATES_HTML_BRANCH}`
    ||env.APP_ENVIRONMENT!=='staging'||env.SUPABASE_PROJECT_REF!==ref||!/^[a-f0-9]{40}$/.test(env.GITHUB_SHA??'')
    ||!env.SUPABASE_ACCESS_TOKEN)throw Error('STAGING_AUTH_PRESERVATION_BOUNDARY');
  const raw=env.FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS;
  const allowed=typeof raw==='string'?raw.split(',').map(x=>x.trim().toLowerCase()).filter(Boolean):[];
  if(allowed.length!==3||new Set(allowed).size!==3||allowed.some(x=>!/^\S+@\S+\.\S+$/.test(x))
    ||![env.TEST_EMAIL_1,env.TEST_EMAIL_2].every(x=>typeof x==='string'&&allowed.includes(x.toLowerCase())))throw Error('STAGING_AUTH_ALLOWLIST_BINDING_REQUIRED');
  const load=async path=>{
    const response=await request(`https://api.supabase.com/v1/projects/${ref}${path}`,{
      method:'GET',headers:{Authorization:`Bearer ${env.SUPABASE_ACCESS_TOKEN}`},signal:AbortSignal.timeout(15000),
    });
    if(!response.ok)throw Error(`STAGING_AUTH_METADATA_${response.status}`);
    return response.json();
  };
  const fn=await load('/functions/send-email-hook');
  if(fn.slug!=='send-email-hook'||fn.status!=='ACTIVE'||fn.verify_jwt!==false||!Number.isSafeInteger(fn.version)||fn.version<1)throw Error('STAGING_AUTH_FUNCTION_NOT_VERIFIED');
  const secrets=await load('/secrets');
  if(!Array.isArray(secrets))throw Error('STAGING_AUTH_SECRET_METADATA_INVALID');
  const expected={APP_ENVIRONMENT:'staging',AUTH_MAIL_MODE:'allowlist',FRIGHTNIGHT_ENABLED:'true',FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS:raw};
  for(const [name,value]of Object.entries(expected)) {
    const rows=secrets.filter(row=>row.name===name);
    if(rows.length!==1||!/^[a-f0-9]{64}$/.test(rows[0].value??'')||rows[0].value!==digest(value))throw Error('STAGING_AUTH_DEPLOYED_POLICY_MISMATCH');
  }
  if(env.EXPECTED_STAGING_AUTH_FUNCTION_VERSION!==undefined&&String(fn.version)!==env.EXPECTED_STAGING_AUTH_FUNCTION_VERSION)throw Error('STAGING_AUTH_FUNCTION_CHANGED');
  return {stagingAuthPolicy:'preserved',functionVersion:fn.version,matchedPolicyDigests:4,allowlistedRecipients:allowed.length,
    existingTestersPreserved:true,authenticationRequests:0,mailDelivery:0,secretMutations:0,readOnly:true};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) {
  stagingAuthPolicy(process.env).then(async proof=>{
    if(process.env.GITHUB_OUTPUT)await appendFile(process.env.GITHUB_OUTPUT,`function_version=${proof.functionVersion}\n`);
    console.log(JSON.stringify(proof));
  }).catch(error=>{console.error(error.message);process.exitCode=1;});
}
