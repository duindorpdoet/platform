import {createHash} from 'node:crypto';
import {describe,expect,it} from 'vitest';
import {assertFrightnightAuthActor,frightnightAuthActorQuery,frightnightAuthPolicy} from './frightnight-auth-policy.mjs';
const env={AUTH_MAIL_MODE:'allowlist',TEST_EMAIL_1:'a@example.invalid',TEST_EMAIL_2:'b@example.invalid',FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS:'a@example.invalid,b@example.invalid,owner@example.invalid',FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID:'11111111-1111-4111-8111-111111111111'};
describe('non-sending staging Auth release gate',()=>{
 it('keeps existing testers and owner in a separate bounded server-only policy',()=>{
  const result=frightnightAuthPolicy(env);
  expect(result.recipientCount).toBe(3);expect(result.digests).toContain(createHash('sha256').update('owner@example.invalid').digest('hex'));
  expect(JSON.stringify(result)).not.toContain('@');
 });
 it.each([{AUTH_MAIL_MODE:'live'},{FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS:undefined},{FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS:''},{FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS:'a@example.invalid,owner@example.invalid'},{FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS:'a@example.invalid,b@example.invalid,invalid'},{FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS:Array.from({length:51},(_,i)=>`t${i}@example.invalid`).join(',')}])('rejects an incomplete or broadened policy before any database read: %j',change=>{
  expect(()=>frightnightAuthPolicy({...env,...change})).toThrow('FRIGHTNIGHT_EXPLICIT_AUTH_ALLOWLIST_REQUIRED');
 });
 it('reads only the exact actor and compares opaque hashes without returning mail addresses',()=>{
  const query=frightnightAuthActorQuery(env);
  expect(query).toContain(`where u.id='${env.FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID}'`);
  expect(query).toContain('email_confirmed_at is not null');expect(query).toContain('banned_until<now()');
  expect(query).toContain("c.capability='event_admin' and c.revoked_at is null");
  expect(query).not.toContain('@');expect(query).not.toMatch(/(?:^|;)\s*(insert|update|delete|drop|alter|grant)\b/i);
  expect(()=>frightnightAuthActorQuery({...env,FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID:"' or true--"})).toThrow('FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID_REQUIRED');
 });
 it('requires confirmed active allowlisted existing actor proof, without an OTP or mail call',()=>{
  const proof={actor_exists:true,actor_active:true,actor_allowlisted:true,actor_is_existing_admin:true};
  expect(()=>assertFrightnightAuthActor(proof)).not.toThrow();
  for(const key of Object.keys(proof))expect(()=>assertFrightnightAuthActor({...proof,[key]:false})).toThrow('FRIGHTNIGHT_OWNER_AUTH_ALLOWLIST_BINDING_FAILED');
  expect(()=>assertFrightnightAuthActor(null)).toThrow('FRIGHTNIGHT_OWNER_AUTH_ALLOWLIST_BINDING_FAILED');
 });
});
