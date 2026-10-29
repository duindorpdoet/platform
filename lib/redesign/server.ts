import 'server-only';
import { createHash, createHmac, randomBytes } from 'node:crypto';
import { createClient } from '@/lib/supabase/server';
import { createPrivilegedClient } from '@/lib/supabase/privileged';
import { serverEnv } from '@/lib/config/server-env';
import { decryptValue, encryptValue, secretBytes } from '@/lib/poortenboek/crypto';
import { ApiError } from '@/lib/http/api';

export async function authenticatedClient() {
  const client = await createClient();
  if(!client)throw new ApiError(503,'AUTH_UNAVAILABLE','De aanmelding is tijdelijk niet bereikbaar.');
  let result;
  try {result=await client.auth.getUser();}catch{throw new ApiError(503,'AUTH_UNAVAILABLE','De aanmelding is tijdelijk niet bereikbaar.');}
  if(result.error&&result.error.name!=='AuthSessionMissingError'&&(!result.error.status||result.error.status>=429))throw new ApiError(503,'AUTH_UNAVAILABLE','De aanmelding is tijdelijk niet bereikbaar.');
  if (result.error || !result.data.user) throw new ApiError(401, 'NOT_AUTHORIZED', 'Log opnieuw in.');
  return { client, actor: result.data.user.id };
}
export async function portalPrint(portalId: string, version?: number) {
  const { actor } = await authenticatedClient(), client = createPrivilegedClient();
  if (!client) throw new ApiError(503, 'UNAVAILABLE', 'Probeer opnieuw zodra de verbinding hersteld is.');
  const key = createHmac('sha256', secretBytes(serverEnv().CHILD_CODE_ENCRYPTION_KEY)).update('portal-print-material-v1').digest('base64');
  const args: Record<string, unknown> = { _actor: actor, _portal_id: portalId, _action: version === undefined ? 'ensure' : 'rotate' };
  {
    const material = { credential: randomBytes(32).toString('hex'), shortCode: randomBytes(6).toString('hex').toUpperCase() };
    Object.assign(args, { ...(version === undefined ? {} : { _expected_version: version }), _ciphertext: encryptValue(JSON.stringify(material), key, `portal-print:${portalId}`),
      _token_hash: '\\x' + createHash('sha256').update(material.credential).digest('hex'),
      _short_hash: '\\x' + createHash('sha256').update(material.shortCode).digest('hex') });
  }
  const result = await client.schema('api').rpc('portal_print_access', args);
  if (result.error) {
    if (result.error.code === '42501' || result.error.message === 'NOT_AUTHORIZED') throw new ApiError(403, 'PRINT_UNAVAILABLE', 'Je hebt geen toegang meer tot deze poort.');
    if (result.error.code === '40001' || /STALE_VERSION/.test(result.error.message)) throw new ApiError(409, 'PRINT_UNAVAILABLE', 'De code is ondertussen gewijzigd. Vernieuw de pagina.');
    throw new ApiError(503, 'PRINT_UNAVAILABLE', 'De QR-code kon tijdelijk niet worden opgehaald. Probeer opnieuw.');
  }
  const { ciphertext, ...safe } = result.data;
  delete safe.credentialId;
  try {
    const material = ciphertext ? JSON.parse(decryptValue(ciphertext, key, `portal-print:${portalId}`)) : null;
    if (!material || !/^[a-f0-9]{64}$/.test(material.credential) || !/^[A-F0-9]{12}$/.test(material.shortCode)) throw new Error('PRINT_MATERIAL_UNAVAILABLE');
    return { ...safe, credential: material.credential as string, shortCode: material.shortCode as string, origin: new URL(serverEnv().APP_URL).origin };
  } catch {
    throw new ApiError(503, 'PRINT_UNAVAILABLE', 'De QR-code kon niet veilig worden opgehaald. Probeer opnieuw.');
  }
}
