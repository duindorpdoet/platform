import 'server-only';
import { createHash, createHmac, randomBytes } from 'node:crypto';
import { createClient } from '@/lib/supabase/server';
import { createPrivilegedClient } from '@/lib/supabase/privileged';
import { serverEnv } from '@/lib/config/server-env';
import { decryptValue, encryptValue, secretBytes } from '@/lib/poortenboek/crypto';
import { ApiError } from '@/lib/http/api';

export async function authenticatedClient() {
  const client = await createClient(), result = await client?.auth.getUser();
  if (!client || result?.error || !result?.data.user) throw new ApiError(401, 'NOT_AUTHORIZED', 'Log opnieuw in.');
  return { client, actor: result.data.user.id };
}
export async function portalPrint(portalId: string, version?: number) {
  const { actor } = await authenticatedClient(), client = createPrivilegedClient();
  if (!client) throw new ApiError(503, 'UNAVAILABLE', 'Probeer opnieuw zodra de verbinding hersteld is.');
  const key = createHmac('sha256', secretBytes(serverEnv().CHILD_CODE_ENCRYPTION_KEY)).update('portal-print-material-v1').digest('base64');
  const args: Record<string, unknown> = { _actor: actor, _portal_id: portalId, _action: version === undefined ? 'read' : 'rotate' };
  if (version !== undefined) {
    const material = { credential: randomBytes(32).toString('hex'), shortCode: randomBytes(6).toString('hex').toUpperCase() };
    Object.assign(args, { _expected_version: version, _ciphertext: encryptValue(JSON.stringify(material), key, `portal-print:${portalId}`),
      _token_hash: '\\x' + createHash('sha256').update(material.credential).digest('hex'),
      _short_hash: '\\x' + createHash('sha256').update(material.shortCode).digest('hex') });
  }
  const result = await client.schema('api').rpc('portal_print_access', args);
  if (result.error) throw new ApiError(/STALE_VERSION/.test(result.error.message) ? 409 : 403, 'PRINT_UNAVAILABLE', 'Controleer je poortrechten en vernieuw de pagina.');
  const { ciphertext, ...safe } = result.data;
  safe.readinessRevision=safe.credentialId?`credential:${safe.credentialId}:${safe.credentialRevision}`:null;
  delete safe.credentialId;
  return { ...safe, ...(ciphertext ? JSON.parse(decryptValue(ciphertext, key, `portal-print:${portalId}`)) : {}), origin: new URL(serverEnv().APP_URL).origin };
}
