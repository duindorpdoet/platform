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

export type TutorialRole = 'parent' | 'house';
export const guidanceEntry = (role: TutorialRole) => role === 'house' ? '/mijn-huis' : '/omgeving/meeloper/nu';

/** Shared client/API contract. Unsafe requests fail; old safe public entries
 * are repaired to the selected role, without assigning that role to anyone. */
export function guidanceReturnPath(value: string | undefined, role: TutorialRole): string {
  const fallback = guidanceEntry(role);
  if (value === undefined || value === '' || value === '/') return fallback;
  if (value.length > 4096 || !value.startsWith('/') || value.startsWith('//')) throw new Error('INVALID_GUIDANCE_PATH');
  let decoded = value;
  for (let i = 0; i < 4; i++) {
    if (/[\\\u0000-\u001f\u007f]/.test(decoded) || decoded.startsWith('//')) throw new Error('INVALID_GUIDANCE_PATH');
    let next: string;
    try { next = decodeURIComponent(decoded); } catch { throw new Error('INVALID_GUIDANCE_PATH'); }
    if (next === decoded) break;
    decoded = next;
  }
  if (/[\\\u0000-\u001f\u007f]/.test(decoded) || decoded.startsWith('//')) throw new Error('INVALID_GUIDANCE_PATH');
  const url = new URL(value, 'https://local.invalid');
  if (url.origin !== 'https://local.invalid') throw new Error('INVALID_GUIDANCE_PATH');
  return guidanceRole(url.pathname) === role ? `${url.pathname}${url.search}${url.hash}` : fallback;
}

/** Stored legacy progress is repairable; incoming API input uses the strict
 * function above so an external URL never becomes a successful request. */
export function resumeGuidancePath(value: string | undefined, role: TutorialRole) {
  try { return guidanceReturnPath(value, role); } catch { return guidanceEntry(role); }
}
export function amsterdamDay(date = new Date()): string {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Amsterdam', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(date);
  return ['year', 'month', 'day'].map(type => parts.find(part => part.type === type)?.value).join('-');
}
