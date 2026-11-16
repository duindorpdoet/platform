import{readFileSync}from'node:fs';
import{describe,it,expect}from'vitest';
const workflow=readFileSync('.github/workflows/deploy-staging.yml','utf8');
const ci=readFileSync('.github/workflows/ci.yml','utf8');
describe('participant update integration preserves the normal FrightNight release boundary',()=>{
  it('retains full backup, preservation, security and exact production promotion gates',()=>{
    for(const gate of ['node scripts/deploy/redesign-backup.mjs','node scripts/deploy/redesign-preflight.mjs','node scripts/deploy/redesign-postmigration.mjs','node scripts/deploy/check-security-advisors.mjs','node scripts/deploy/verify-mail-provider.mjs'])expect(workflow).toContain(gate);
    expect(readFileSync('.github/workflows/deploy-production.yml','utf8')).toContain('node scripts/deploy/require-staging-success.mjs');
    expect(ci).toContain('pnpm exec playwright test --config playwright.participant-updates.config.ts');
    expect(ci).toContain('pnpm exec playwright test --config playwright.frightnight.config.ts');
  });
  it('keeps the staging Auth allowlist and sink before initialization without a legacy live-mail branch',()=>{
    expect(workflow).toContain('AUTH_MAIL_MODE: allowlist');
    expect(workflow).not.toMatch(/AUTH_MAIL_MODE:\s*live/);
    expect(workflow).toContain('FRIGHTNIGHT_MAIL_MODE: sink');
    expect(workflow).toContain('EVENT_SLUG: frightnight-2027-test');
    expect(workflow).toContain('FRIGHTNIGHT_PROJECT_REF: nocteiuvohesvqbowchw');
    expect(workflow).toContain('FRIGHTNIGHT_HARDWARE_ENABLED: "false"');
    const hook=workflow.indexOf('- name: Deploy shared signed email hook');
    const binding=workflow.indexOf('- name: Prove owner Auth allowlist binding without requesting authentication mail');
    const seed=workflow.indexOf('- name: Initialize only ownerless synthetic 2027 records without auth or mail delivery');
    expect(hook).toBeGreaterThan(0);expect(binding).toBeGreaterThan(hook);expect(seed).toBeGreaterThan(binding);
    expect(workflow).not.toContain('preserve-staging-auth.mjs');
    const runtime=workflow.match(/DG_RUNTIME_ENV_KEYS: >-\n([\s\S]*?)\n    steps:/)?.[1]??'';
    for(const key of ['FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS','FRIGHTNIGHT_MAIL_MODE','FRIGHTNIGHT_PAYMENT_PROVIDER','FRIGHTNIGHT_HARDWARE_ENABLED'])expect(runtime).toContain(key);
  });
  it('retains no-OTP mail acceptance, private account, bounded-load and scenario restoration gates',()=>{
    const mail=workflow.slice(workflow.indexOf('\n  mail-acceptance:'),workflow.indexOf('\n  frightnight-load-acceptance:'));
    expect(mail).toContain('Verify isolated sink and Auth configuration without requesting codes');
    expect(mail).toContain('node scripts/deploy/check-frightnight-safety.mjs');
    expect(mail).toContain('node scripts/deploy/check-frightnight-public-rpc.mjs');
    expect(mail).not.toContain('staging_mail.py');
    expect(workflow).toContain('node scripts/acceptance/frightnight-staging.mjs');
    expect(workflow).toContain('node scripts/acceptance/frightnight-load.mjs');
    expect(workflow).toContain('FRIGHTNIGHT_SCENARIO_BACKUP: "true"');
    expect(workflow).toContain('needs: [deploy, account-app-acceptance, mail-acceptance, frightnight-load-acceptance]');
  });
});
