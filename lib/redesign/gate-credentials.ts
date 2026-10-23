export function gateArrivalUrl(portal: { id: string }, credential: string, origin: string) {
  const url = new URL('/omgeving/meeloper/route', origin);
  if (url.protocol !== 'https:' && url.hostname !== 'localhost') throw new Error('INVALID_ORIGIN');
  url.search = new URLSearchParams({ poort: portal.id, code: credential }).toString();
  return url.href;
}

/** Preserve case for existing hexadecimal QR tokens; only short codes normalize. */
export function parseGateCredential(input: string): { credential: string; portalId?: string } {
  let credential = input.trim(), portalId: string | undefined;
  if (/^https?:\/\//i.test(credential)) {
    const url = new URL(credential);
    if (url.origin !== window.location.origin || !['/omgeving/meeloper/route', '/mijn-groep'].includes(url.pathname)) throw new Error('WRONG_PORTAL');
    credential = url.searchParams.get('code') ?? url.searchParams.get('token') ?? '';
    portalId = url.searchParams.get('poort') ?? undefined;
  }
  if (!/^[a-zA-Z0-9_-]{4,160}$/.test(credential)) throw new Error('WRONG_PORTAL');
  return { credential, portalId };
}
