import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {assertFrightnightRelease} from './frightnight-release.mjs';

export function frightnightAuthPolicy(env) {
  const recipients=[...new Set((env.FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS??'').split(',').map(v=>v.trim().toLowerCase()).filter(Boolean))];
  const existing=[env.TEST_EMAIL_1,env.TEST_EMAIL_2].map(v=>v?.trim().toLowerCase());
  if(env.AUTH_MAIL_MODE!=='allowlist'||!recipients.length||recipients.length>50||recipients.some(v=>!/^[^\s@,]+@[^\s@,]+\.[^\s@,]+$/.test(v))||existing.some(v=>!v||!recipients.includes(v))||new Set(existing).size!==2)throw new Error('FRIGHTNIGHT_EXPLICIT_AUTH_ALLOWLIST_REQUIRED');
  return {recipientCount:recipients.length,digests:recipients.map(v=>createHash('sha256').update(v).digest('hex'))};
}

export function frightnightAuthActorQuery(env) {
  const policy=frightnightAuthPolicy(env);
  const actor=env.FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID;
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(actor??''))throw new Error('FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID_REQUIRED');
  return `select count(*)=1 as actor_exists,
    coalesce(bool_and(u.email_confirmed_at is not null and u.deleted_at is null and (u.banned_until is null or u.banned_until<now())),false) as actor_active,
    coalesce(bool_and(encode(sha256(convert_to(lower(trim(u.email)),'UTF8')),'hex')=any(array[${policy.digests.map(v=>`'${v}'`).join(',')}])),false) as actor_allowlisted,
    coalesce(bool_and(exists(select 1 from app_private.event_capabilities c where c.user_id=u.id and c.capability='event_admin' and c.revoked_at is null)),false) as actor_is_existing_admin
    from auth.users u where u.id='${actor}'`;
}

export function assertFrightnightAuthActor(row) {
  if(!row||row.actor_exists!==true||row.actor_active!==true||row.actor_allowlisted!==true||row.actor_is_existing_admin!==true)throw new Error('FRIGHTNIGHT_OWNER_AUTH_ALLOWLIST_BINDING_FAILED');
}

async function main() {
  assertFrightnightRelease(process.env);
  const policy=frightnightAuthPolicy(process.env);
  const {management}=await import('./redesign-preflight.mjs');
  const rows=await management('/database/query',{read_only:true,query:frightnightAuthActorQuery(process.env)});
  assertFrightnightAuthActor(rows[0]);
  console.log(JSON.stringify({authPolicy:'explicit-staging-allowlist',recipientCount:policy.recipientCount,verifiedOwnerAllowed:true,existingTestersPreserved:true,readOnly:true,authenticationRequests:0,mailDelivery:0}));
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)await main();
