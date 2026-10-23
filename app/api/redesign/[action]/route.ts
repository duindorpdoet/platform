import { z } from 'zod';
import { NextResponse } from 'next/server';
import { apiFailure, ApiError, assertTrustedOrigin, correlationId } from '@/lib/http/api';
import { authenticatedClient, portalPrint } from '@/lib/redesign/server';
import { serverEnv } from '@/lib/config/server-env';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';
type Context = { params: Promise<{ action: string }> };
const response = (data: unknown) => NextResponse.json(data, { headers: { 'Cache-Control': 'private, no-store', 'X-Robots-Tag': 'noindex, nofollow', Vary: 'Cookie' } });

export async function GET(request: Request, context: Context) {
  try {
    const { action } = await context.params, params = new URL(request.url).searchParams;
    if (action === 'poster') return response(await portalPrint(z.uuid().parse(params.get('portalId'))));
    const { client } = await authenticatedClient();
    let result;
    if (action === 'guidance') result = await client.schema('api').rpc('participant_guidance', { _event_slug: serverEnv().EVENT_SLUG });
    else if (action === 'thanks') result = await client.schema('api').rpc('portal_thanks_snapshot', { _event_slug: serverEnv().EVENT_SLUG, _scope: z.enum(['family', 'house', 'admin']).parse(params.get('scope') ?? 'family'), _portal_id: params.has('portalId') ? z.uuid().parse(params.get('portalId')) : null });
    else throw new ApiError(404, 'NOT_FOUND', 'Niet gevonden.');
    if (result.error) {
      if(result.error.message==='NOT_AUTHORIZED'||result.error.code==='42501')throw new ApiError(403, 'NOT_AUTHORIZED', 'Dit onderdeel is niet beschikbaar voor jouw account.');
      throw new ApiError(500,'FETCH_FAILED','Dit onderdeel kon niet worden opgehaald. Probeer opnieuw.');
    }
    return response(result.data);
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
export async function POST(request: Request, context: Context) {
  try {
    assertTrustedOrigin(request);
    // Bound actual streamed bytes, including chunked requests.
    const reader = request.body?.getReader();
    if (!reader) throw new ApiError(400, 'INVALID_INPUT', 'Controleer je invoer.');
    const chunks: Uint8Array[] = []; let size = 0;
    try { for (;;) { const { done, value } = await reader.read(); if (done) break; size += value.byteLength; if (size > 16384) { await reader.cancel(); throw new ApiError(413, 'INVALID_INPUT', 'Dit verzoek is te groot.'); } chunks.push(value); } } finally { reader.releaseLock(); }
    const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    const { action } = await context.params;
    if (action === 'poster') { const data = z.object({ portalId: z.uuid(), version: z.number().int().positive(), confirmRotation: z.literal(true) }).parse(input); return response(await portalPrint(data.portalId, data.version)); }
    const { client } = await authenticatedClient(); let result;
    if (action === 'rehearsal') {
      const data=z.object({scenario:z.enum(['start','arrival','inclusive','wrong','duplicate','closed','manual','offline','stale','early','part-departure','finale'])}).parse(input);
      result=await client.schema('api').rpc('redesign_rehearsal',{_event_slug:serverEnv().EVENT_SLUG,_scenario:data.scenario});
    } else if (action === 'guidance') {
      const data = z.discriminatedUnion('action', [z.object({ action: z.literal('acknowledge') }), z.object({ action: z.literal('tutorial'), role: z.enum(['parent', 'house']), version: z.literal(1), index: z.number().int().min(0).max(13), completed: z.boolean().optional(), returnPath: z.string().max(4096).regex(/^\/[^/]/) })]).parse(input);
      result = await client.schema('api').rpc('participant_guidance', { _event_slug: serverEnv().EVENT_SLUG, _action: data.action, _role: 'role' in data ? data.role : null, _payload: data });
    } else if (action === 'thanks') {
      const data = z.object({ portalId: z.uuid(), choice: z.enum(['beautiful', 'welcome', 'treats']) }).parse(input);
      result = await client.schema('api').rpc('portal_thanks_save', { _event_slug: serverEnv().EVENT_SLUG, _portal_id: data.portalId, _choice: data.choice });
    } else throw new ApiError(404, 'NOT_FOUND', 'Niet gevonden.');
    if (result.error) throw new ApiError(409, 'SAVE_FAILED', 'Dit kon niet worden opgeslagen. Vernieuw de actuele stand en probeer opnieuw.');
    return response(result.data);
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
