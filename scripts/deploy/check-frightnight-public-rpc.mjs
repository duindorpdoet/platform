import { assertFrightnightRelease } from './frightnight-release.mjs';

const target = assertFrightnightRelease(process.env);
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
if (!key) throw new Error('FRIGHTNIGHT_PUBLIC_API_KEY_REQUIRED');
const base = `https://${target.projectRef}.supabase.co`;
const headers = {apikey:key,Authorization:`Bearer ${key}`,'Content-Type':'application/json','Content-Profile':'api'};
const auth = await fetch(`${base}/auth/v1/settings`, {headers:{apikey:key},signal:AbortSignal.timeout(15000)});
if (!auth.ok) throw new Error(`FRIGHTNIGHT_AUTH_SETTINGS_${auth.status}`);
const settings = await auth.json();
if (settings.external?.email !== true || settings.mailer_autoconfirm !== false) throw new Error('FRIGHTNIGHT_VERIFIED_EMAIL_AUTH_REQUIRED');
const denied = await fetch(`${base}/rest/v1/rpc/frightnight_snapshot`, {
  method:'POST',headers,body:JSON.stringify({p_slug:target.slug}),signal:AbortSignal.timeout(15000),
});
const error = await denied.json();
if (![401,403].includes(denied.status) || error.code !== '42501') throw new Error('FRIGHTNIGHT_ANONYMOUS_RPC_NOT_DENIED');
const privateSchema = await fetch(`${base}/rest/v1/rpc/frightnight_snapshot`, {
  method:'POST',headers:{...headers,'Content-Profile':'app_private'},body:JSON.stringify({p_slug:target.slug}),signal:AbortSignal.timeout(15000),
});
const privateError = await privateSchema.json();
if (privateSchema.status !== 406 || privateError.code !== 'PGRST106') throw new Error('FRIGHTNIGHT_PRIVATE_SCHEMA_EXPOSED');
console.log('Real public Auth configuration, denied anonymous FrightNight RPC and unexposed private schema verified. No OTP, mail, push, payment or data mutation requested.');
