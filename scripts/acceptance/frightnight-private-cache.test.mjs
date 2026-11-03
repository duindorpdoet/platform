import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { hasPrivateNoStore } from './frightnight-private-cache.mjs';

test('accepts route and deployed private no-store policies including zero freshness', () => {
  for (const policy of ['private, no-store', 'private, no-store, max-age=0', ' NO-STORE , PRIVATE , MAX-AGE = 0 ', 'private,no-store,max-age="0",no-cache,must-revalidate', 'private,no-store,no-transform,proxy-revalidate']) {
    assert.equal(hasPrivateNoStore(policy), true, policy);
  }
});

test('requires both full private and no-store directives', () => {
  for (const policy of [undefined, null, '', 'no-store', 'private', 'no-cache, max-age=0', 'private, no-cache', 'public, no-store', 'private="Set-Cookie",no-store', 'private,no-store=0']) {
    assert.equal(hasPrivateNoStore(policy), false, String(policy));
  }
});

test('rejects shared, positive, contradictory and stale freshness even beside no-store', () => {
  for (const extension of ['public', 's-maxage=0', 's-maxage=60', 'max-age=1', 'max-age=-1', 'max-age="60"', 'max-age=0.0', 'max-age', 'stale-while-revalidate=60', 'stale-if-error=60', 'max-stale=0', 'min-fresh=0', 'immutable', 'unknown-extension']) {
    assert.equal(hasPrivateNoStore(`private,no-store,${extension}`), false, extension);
  }
});

test('rejects duplicate or malformed directives instead of choosing a client-wins value', () => {
  for (const policy of ['private,no-store,max-age=0,max-age=10', 'private,no-store,max-age=10,max-age=0', 'private,no-store,private', 'private,no-store,', 'private no-store', 'private,no-store\r\npublic', 'private,no-store,max-age="0', 'private,no-store,' + 'x'.repeat(2048)]) {
    assert.equal(hasPrivateNoStore(policy), false, policy.slice(0,100));
  }
});

test('all five hosted private download checks share the same semantic boundary', () => {
  const source = readFileSync(new URL('./frightnight-staging.mjs', import.meta.url), 'utf8');
  for (const response of ['previewMail', 'adminReadsOwnerPhoto', 'ownerReadsAdminPhoto', 'svgResponse', 'operationalEmergency']) {
    assert.ok(source.includes(`hasPrivateNoStore(${response}.headers()['cache-control'])`), response);
  }
  assert.equal(source.includes("['cache-control']==='private, no-store'"), false);
  assert.ok(source.includes('MAIL_CAPTURE_PREVIEW_BOUNDARY_FAILED'));
  assert.ok(source.includes(".includes(\"default-src 'none'\")"));
  assert.ok(source.includes('PERSONAL_SVG_PASS_PRIVATE_DATA_LEAK'));
  assert.ok(source.includes('STORAGE_RLS_FOREIGN_PHOTO_EXPOSED'));
  assert.ok(source.includes('PARTICIPANT_EMERGENCY_FUTURE_ADDRESS_LEAK'));
});
