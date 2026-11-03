import { management } from './redesign-preflight.mjs';
import { assertFrightnightRelease, assertFrightnightSafety, FRIGHTNIGHT_SAFETY_SQL } from './frightnight-release.mjs';

const target = assertFrightnightRelease(process.env);
const before = await management('/database/query', { read_only: true, query: FRIGHTNIGHT_SAFETY_SQL });
const safety = assertFrightnightSafety(before[0]?.frightnight_safety, false);
if (!safety.edition) {
  // A named organization account is chosen outside this script. Never select an
  // arbitrary historical admin or automatically copy 2026 role assignments.
  if (!process.env.FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID || !process.env.SUPABASE_SERVICE_ROLE_KEY) throw new Error('FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID_REQUIRED');
  const response = await fetch(`https://${target.projectRef}.supabase.co/rest/v1/rpc/frightnight_bootstrap`, {
    method:'POST', headers:{apikey:process.env.SUPABASE_SERVICE_ROLE_KEY,Authorization:`Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}`,'Content-Type':'application/json','Content-Profile':'api'},
    body:JSON.stringify({p_slug:target.slug,p_actor:process.env.FRIGHTNIGHT_BOOTSTRAP_ACTOR_ID,p_environment:'staging',p_confirmation:`${target.projectRef}:staging:duindorphalloweenstg`}),
    signal:AbortSignal.timeout(15000),
  });
  if (!response.ok) throw new Error(`FRIGHTNIGHT_BOOTSTRAP_REJECTED_${response.status}`);
  await response.body?.cancel();
}
const after = await management('/database/query', { read_only: true, query: FRIGHTNIGHT_SAFETY_SQL });
assertFrightnightSafety(after[0]?.frightnight_safety);
console.log('Explicit 2027 staging edition configured. No synthetic household, payment, message, OTP or push created.');
