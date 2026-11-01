import { actorSnapshot } from '@/lib/duinpad/actors';
import { apiSuccess, apiFailure, correlationId } from '@/lib/http/api';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export async function GET(request: Request) {
  try { return apiSuccess(await actorSnapshot()); }
  catch (error) { return apiFailure(error, correlationId(request)); }
}
