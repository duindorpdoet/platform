import { randomUUID } from 'node:crypto';
import { assertFrightnightRelease } from './frightnight-release.mjs';

export async function verifyFrightnightDeployment(get, health, env = process.env) {
  const target = assertFrightnightRelease(env);
  if (health.eventSlug !== target.slug || health.brand !== 'frightnight-2027-v7' || health.paymentProvider !== env.FRIGHTNIGHT_PAYMENT_PROVIDER) throw new Error('FRIGHTNIGHT_HEALTH_BINDING_MISMATCH');
  for (const path of ['/', '/inloggen', '/nachtpas', '/mijn-zone', '/avondregie', '/testcentrum', '/privacy', '/voorwaarden', '/toegankelijkheid']) {
    const response = await get(path);
    if (!response.ok) throw new Error(`FRIGHTNIGHT_PAGE_${path}_${response.status}`);
    const html = await response.text();
    if (!html.includes('FrightNight')) throw new Error(`FRIGHTNIGHT_BRANDING_MISSING_${path}`);
  }
  for (const path of ['/api/frightnight/snapshot','/api/frightnight/pass','/api/frightnight/emergency','/api/frightnight/qr','/api/frightnight/walk?destinationId=00000000-0000-4000-8000-000000000001']) {
    const response = await get(path);
    if (response.status !== 401 || !response.headers.get('cache-control')?.includes('no-store')) throw new Error(`FRIGHTNIGHT_PRIVATE_API_${path}`);
    await response.body?.cancel();
  }
  for (const origin of [target.origin, 'https://untrusted.example.invalid']) {
    const response = await get('/api/frightnight/command', {
      method:'POST', headers:{Origin:origin,'Content-Type':'application/json'},
      body:JSON.stringify({commandId:randomUUID(),operation:'registration.save',payload:{}}),
    });
    if (response.status !== (origin === target.origin ? 401 : 403)) throw new Error('FRIGHTNIGHT_COMMAND_AUTHORIZATION_FAILED');
    await response.body?.cancel();
  }
  const manifestResponse = await get('/manifest.webmanifest');
  const manifest = await manifestResponse.json();
  if (!manifestResponse.ok || !manifest.name?.includes('FrightNight') || manifest.start_url !== '/nachtpas'
      || !manifest.icons?.some(icon => icon.purpose === 'maskable')) throw new Error('FRIGHTNIGHT_MANIFEST_MISMATCH');
  for (const path of ['/sw.js','/offline.html','/frightnight/king-head.webp','/frightnight/kraaienbode.webp','/frightnight/oogstdorp.webp']) {
    const response = await get(path);
    if (!response.ok) throw new Error(`FRIGHTNIGHT_ASSET_${path}`);
    if (path === '/offline.html') {
      if (!(await response.text()).includes('Duinpad')) throw new Error('FRIGHTNIGHT_OFFLINE_HELP_MISSING');
    } else await response.body?.cancel();
  }
  console.log(`FrightNight ${env.GITHUB_SHA}: public pages, private APIs, origin checks, PWA and independent help passed. Provider=${env.FRIGHTNIGHT_PAYMENT_PROVIDER}; external PSP acceptance is separate.`);
}
