import { execFileSync } from 'node:child_process';

// A nonexistent UUID proves parameter conversion without mutating business data.
for (const name of ['worker_update_outbox', 'worker_update_outbox_v2']) {
  const secret = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const response = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { apikey: secret, Authorization: `Bearer ${secret}`, 'Content-Type': 'application/json', 'Content-Profile': 'api' },
    body: JSON.stringify({ _id: '00000000-0000-0000-0000-000000000000', _status: 'accepted' }),
    signal: AbortSignal.timeout(10000),
  });
  const body = await response.json().catch(() => null);
  const code = typeof body?.code === 'string' && /^[A-Z0-9_]{1,100}$/.test(body.code) ? body.code : 'NO_CODE';
  console.log(JSON.stringify({ rpc: name, http: response.status, code, outboxChanged: false }));
  if (process.argv.includes('--require-v2') && name === 'worker_update_outbox_v2' && (code !== 'P0001' || body?.message !== 'OUTBOX_NOT_FOUND')) throw new Error('TEXT_STATUS_RPC_NOT_USABLE');
}
try {
  const logs = execFileSync('journalctl', ['--user', '--since', '2026-10-28 00:00:00 UTC', '--no-pager', '--output=cat'], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  for (const code of ['MAIL_STATUS_STORE_FAILED', '42501']) {
    console.log(JSON.stringify({ code, occurrences: logs.split(code).length - 1 }));
  }
  const digests = [...logs.matchAll(/digest: ['"]([0-9]+)['"]/g)].map(match => match[1]);
  console.log(JSON.stringify({ correlationIds: [...new Set(digests)] }));
} catch {
  console.log(JSON.stringify({ code: 'APPLICATION_JOURNAL_UNAVAILABLE' }));
}
