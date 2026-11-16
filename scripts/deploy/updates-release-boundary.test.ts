import{readFileSync}from'node:fs';
import{describe,it,expect}from'vitest';
import{UPDATES_HTML_BRANCH}from'./staging-installed-history.mjs';
const workflow=readFileSync('.github/workflows/deploy-staging.yml','utf8');
const ref=`refs/heads/${UPDATES_HTML_BRANCH}`;
describe('isolated update hotfix release boundaries',()=>{
  it('retains full backup, preservation, security and exact production promotion gates',()=>{
    for(const gate of ['node scripts/deploy/redesign-backup.mjs','node scripts/deploy/redesign-preflight.mjs','node scripts/deploy/redesign-postmigration.mjs','node scripts/deploy/check-security-advisors.mjs','node scripts/deploy/verify-mail-provider.mjs'])expect(workflow).toContain(gate);
    expect(readFileSync('.github/workflows/deploy-production.yml','utf8')).toContain('node scripts/deploy/require-staging-success.mjs');
    expect(readFileSync('.github/workflows/ci.yml','utf8')).toContain(`      - ${UPDATES_HTML_BRANCH}`);
    expect(readFileSync('.github/workflows/ci.yml','utf8')).toContain('pnpm exec playwright test --config playwright.participant-updates.config.ts');
  });
  it('restores the own local database after committed closure before independent planboard and mail scenarios',()=>{
    const ci=readFileSync('.github/workflows/ci.yml','utf8');
    const closed=ci.indexOf('- name: Verify closed Poortkamer thanks through real Auth, HTTP and database');
    const reset=ci.indexOf('- name: Restore isolated fixtures after closed Poortkamer acceptance');
    const benchmark=ci.indexOf('- name: Measure bounded planboard reads on synthetic event sizes');
    const mail=ci.indexOf('- name: Exercise full planboard and signed Resend mail chain locally');
    expect(closed).toBeGreaterThan(0);expect(reset).toBeGreaterThan(closed);
    expect(benchmark).toBeGreaterThan(reset);expect(mail).toBeGreaterThan(benchmark);
    expect(ci.slice(closed,reset)).toContain('pnpm exec playwright test --config playwright.poortkamer-thanks-closed.config.ts');
    expect(ci.slice(reset,benchmark)).toMatch(/run: pnpm exec supabase db reset\s*$/);
    expect(ci.slice(reset,benchmark).match(/supabase db reset/g)).toHaveLength(1);
  });
  it('preserves the installed Auth hook and verifies actual policy before and after app deployment',()=>{
    expect(workflow).toContain(`- name: Deploy shared signed email hook\n        if: github.ref != '${ref}'`);
    const before=workflow.indexOf('- name: Prove the existing staging Auth allowlist without requesting codes');
    const deploy=workflow.indexOf('/usr/local/bin/dg-site-deploy');
    const after=workflow.indexOf('- name: Recheck unchanged staging Auth policy');
    expect(before).toBeGreaterThan(0);expect(deploy).toBeGreaterThan(before);expect(after).toBeGreaterThan(deploy);
    expect(workflow).toContain('EXPECTED_STAGING_AUTH_FUNCTION_VERSION: ${{ steps.staging-auth-policy.outputs.function_version }}');
  });
  it('keeps a mandatory no-send mail acceptance instead of automatic OTP on this exact branch',()=>{
    const mail=workflow.slice(workflow.indexOf('\n  mail-acceptance:'));
    expect(mail).toContain(`- name: Verify allowed-mailbox OTP and transaction delivery\n        if: github.ref != '${ref}'`);
    expect(mail).toContain(`- name: Verify preserved Auth allowlist without requesting or delivering mail\n        if: github.ref == '${ref}'`);
    expect(mail).toContain('EXPECTED_STAGING_AUTH_FUNCTION_VERSION: ${{ needs.deploy.outputs.staging_auth_function_version }}');
    expect(mail).toContain('run: node scripts/deploy/preserve-staging-auth.mjs');
    const runtime=workflow.match(/DG_RUNTIME_ENV_KEYS: >-\n([\s\S]*?)\n    steps:/)?.[1]??'';
    expect(runtime).not.toContain('FRIGHTNIGHT_AUTH_ALLOWED_RECIPIENTS');
  });
});
