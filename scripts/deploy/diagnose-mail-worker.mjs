import { execFileSync } from 'node:child_process';
import { readdir, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';

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
const sources=[];
const journalArgs=['--since','2026-10-28 00:00:00 UTC','--no-pager','--output=cat'];
const run=(command,args)=>execFileSync(command,args,{encoding:'utf8',maxBuffer:32*1024*1024,stdio:['ignore','pipe','pipe']});
try { sources.push(run('journalctl',['--user',...journalArgs])); } catch { /* Dedicated service may use the system journal. */ }
const site=process.env.APP_ENVIRONMENT==='staging'?'duindorphalloweenstg':'duindorphalloweenprod';
for(const scope of [[],['--user']]) {
  try {
    const units=run('systemctl',[...scope,'list-units','--all','--type=service','--no-legend','--plain']).split('\n').map(line=>line.trim().split(/\s+/)[0]).filter(unit=>/^[a-zA-Z0-9@_.-]+\.service$/.test(unit)&&unit.includes(site)&&!unit.includes('runner'));
    for(const unit of units)try { sources.push(run('journalctl',[...scope,'-u',unit,...journalArgs])); } catch { /* Try own application log files below. */ }
  } catch { /* Systemd may be unavailable in the runner session. */ }
}
for(const directory of [`/srv/sites/${site}/logs`,`/srv/sites/${site}/shared/logs`,`/srv/sites/${site}/shared`,`/var/log/dg-sites`]) {
  try {
    for(const entry of await readdir(directory,{withFileTypes:true})) {
      if(!entry.isFile()||!new RegExp(`^(?:app|error|output|runtime|stderr|stdout|server|${site})[a-z0-9._-]*\\.log$`,'i').test(entry.name))continue;
      const path=join(directory,entry.name),info=await stat(path);
      if(info.size>32*1024*1024||info.mtimeMs<Date.parse('2026-10-28T00:00:00Z'))continue;
      sources.push(await readFile(path,'utf8'));
    }
  } catch { /* Optional deployment-specific log directory. */ }
}
if(sources.length) {
  const logs=sources.join('\n');
  for (const code of ['MAIL_STATUS_STORE_FAILED', '42501']) {
    console.log(JSON.stringify({ code, occurrences: logs.split(code).length - 1 }));
  }
  const digests = [...logs.matchAll(/digest: ['"]([0-9]+)['"]/g)].map(match => match[1]);
  console.log(JSON.stringify({ correlationIds: [...new Set(digests)] }));
} else {
  console.log(JSON.stringify({ code: 'APPLICATION_LOG_UNAVAILABLE' }));
}
