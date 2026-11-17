// QA preload only: fail closed on every non-loopback native fetch.
import { appendFileSync } from 'node:fs';
const originalFetch = globalThis.fetch.bind(globalThis);
const log = '/tmp/frightnight-env04-network.jsonl';
function effectivePolicy() {
  const present = Object.hasOwn(process.env, 'FRIGHTNIGHT_MAIL_MODE');
  return { mailPolicyVariablePresent: present, mailPolicyClass: !present ? 'missing' : ['sink', 'allowlist'].includes(process.env.FRIGHTNIGHT_MAIL_MODE) ? process.env.FRIGHTNIGHT_MAIL_MODE : 'invalid' };
}
appendFileSync(log, JSON.stringify({ phase: 'preload', pid: process.pid, ...effectivePolicy() }) + '\n', { mode: 0o600 });
globalThis.fetch = async (input, init) => {
  const address = input instanceof Request ? input.url : String(input);
  const url = new URL(address);
  const allowed = url.protocol === 'http:' && ['127.0.0.1', 'localhost'].includes(url.hostname) && ['63561', '63562', '63563', '3137', '3140'].includes(url.port);
  appendFileSync(log, JSON.stringify({ phase: 'fetch', pid: process.pid, host: url.hostname, method: init?.method ?? (input instanceof Request ? input.method : 'GET'), blocked: !allowed, ...effectivePolicy() }) + '\n', { mode: 0o600 });
  if (!allowed) throw new Error('QA_EXTERNAL_NETWORK_BLOCKED');
  return originalFetch(input, init);
};
