export const GUIDANCE_VERSION = 1;
export type GuidanceRole = 'parent' | 'house' | 'viewer' | 'admin';
export type GuidanceProgress = { version: number; index: number; returnPath: string };
export type GuidanceRecord = { userId: string; eventId: string; groupId?: string; today: string; roles: GuidanceRole[]; acknowledgedDay: string | null; welcomeVersion?: number; completed: Partial<Record<GuidanceRole, number>>; progress?: Partial<Record<'parent' | 'house', GuidanceProgress>> };
export function guidanceRole(path: string): GuidanceRole | null {
  if (path.startsWith('/admin')) return 'admin';
  if (path==='/omgeving/kiezen' || path==='/app' || path.startsWith('/app/')) return null;
  if (path === '/mijn-huis' || path.startsWith('/poortkamer') || path.startsWith('/omgeving/huiseigenaar')) return 'house';
  if (path.startsWith('/omgeving/meekijker')) return 'viewer';
  if (path === '/mijn-inschrijving' || path === '/mijn-groep' || (path.startsWith('/omgeving') && !path.startsWith('/omgeving/nieuws'))) return 'parent';
  return null;
}
export function amsterdamDay(date = new Date()): string {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Amsterdam', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(date);
  return ['year', 'month', 'day'].map(type => parts.find(part => part.type === type)?.value).join('-');
}
