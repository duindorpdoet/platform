import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const read = (path: string) => readFileSync(path, "utf8");

function jobs(source: string) {
  const section = source.slice(source.indexOf("\njobs:\n") + "\njobs:\n".length);
  const headers = [...section.matchAll(/^  ([a-z][a-z0-9-]*):[ \t]*$/gm)];
  return new Map(headers.map((header, index) => [header[1], section.slice(header.index, headers[index + 1]?.index)]));
}

function ordered(source: string, ...checks: string[]) {
  let previous = -1;
  for (const check of checks) {
    const index = source.indexOf(check);
    expect(index, `${check} remains required`).toBeGreaterThanOrEqual(0);
    expect(index, `${check} retains its release ordering`).toBeGreaterThan(previous);
    previous = index;
  }
}

describe("explicit release read transport workflow contract", () => {
  it("pins the reviewed native driver in both the manifest and frozen lockfile", () => {
    const manifest = JSON.parse(read("package.json"));
    expect(manifest.devDependencies["@supabase/pg"]).toBe("8.21.1");
    const locked = read("pnpm-lock.yaml").match(/      '@supabase\/pg':\n(?:[^\n]+\n){2}/)?.[0];
    expect(locked).toMatch(/specifier: 8\.21\.1\s*\n\s+version: 8\.21\.1(?:\(|\s|$)/);
  });

  it.each(["staging", "production"])("enables the native read path only in normal %s backup and deployment jobs", environment => {
    const source = read(`.github/workflows/deploy-${environment}.yml`);
    const entries = jobs(source);
    const enabled = [...entries].filter(([, body]) => body.includes("RELEASE_READ_TRANSPORT:")).map(([name]) => name).sort();
    expect(enabled).toEqual(["backup-restore", "deploy"]);
    expect(source.slice(0, source.indexOf("\njobs:\n"))).not.toContain("RELEASE_READ_TRANSPORT");
    for (const name of enabled) {
      const body = entries.get(name)!;
      if (environment === "production") {
        expect(body).toContain("RELEASE_READ_TRANSPORT: session-pooler");
        expect(body).toContain("!inputs.database_connection_diagnostics");
        expect(body).toContain("!inputs.database_connection_recovery");
      } else {
        // Existing isolated branch deployments retain their previous path;
        // regular staging exercises the same path as production.
        expect(body).toContain("RELEASE_READ_TRANSPORT: ${{ github.ref == 'refs/heads/staging' && 'session-pooler' || '' }}");
      }
      expect(body).toContain("SUPABASE_PROJECT_REF: ${{ vars.SUPABASE_PROJECT_REF }}");
      expect(body).toContain("SUPABASE_DB_PASSWORD: ${{ secrets.SUPABASE_DB_PASSWORD }}");
      expect(body).toContain("ref: ${{ github.sha }}");
    }
  });

  it.each(["staging", "production"])("installs the frozen native driver before the first %s backup read", environment => {
    const backup = jobs(read(`.github/workflows/deploy-${environment}.yml`)).get("backup-restore")!;
    ordered(backup, "node-version: 24", "npm install --global pnpm@11.25.0", "pnpm install --frozen-lockfile");
    const installed = backup.indexOf("pnpm install --frozen-lockfile");
    for (const script of ["repair-portal-hotfix-history.mjs", "redesign-backup.mjs", ...(environment === "production" ? ["evening-readiness-audit.mjs"] : [])]) {
      expect(backup.indexOf(`node scripts/deploy/${script}`), script).toBeGreaterThan(installed);
    }
    expect(backup).toContain("run: node scripts/deploy/redesign-backup.mjs");
    expect(backup).toContain("actions/upload-artifact@");
    expect(backup).toContain("duindorp-release-backup/");
  });

  it.each(["staging", "production"])("preserves exact revision, restore, migration, data and HTTP gates for %s", environment => {
    const source = read(`.github/workflows/deploy-${environment}.yml`);
    const entries = jobs(source), deployment = entries.get("deploy")!;
    expect(deployment).toContain("needs: [backup-restore, release-policy]");
    expect(deployment).toContain("APP_REVISION: ${{ github.sha }}");
    expect(deployment).toContain("SKIP_MAIL_TESTS: ${{ needs.release-policy.outputs.skip_mail_tests }}");
    expect(deployment).toContain("actions/download-artifact@");
    ordered(deployment,
      "pnpm install --frozen-lockfile",
      "run: node scripts/deploy/inspect-finale-planning.mjs",
      "run: pnpm verify",
      "run: node scripts/deploy/redesign-preflight.mjs",
      `Link and migrate ${environment} database`,
      "run: node scripts/deploy/redesign-postmigration.mjs",
      "/usr/local/bin/dg-site-deploy",
      "run: node scripts/deploy/check-security-advisors.mjs",
      `run: node scripts/deploy/verify-deployment.mjs ${environment}`,
      "run: node scripts/deploy/check-startregie-reads.mjs",
    );
    if (environment === "production") {
      for (const name of ["backup-restore", "deploy"]) expect(entries.get(name)).toContain("run: node scripts/deploy/require-staging-success.mjs");
      expect(deployment).toContain("run: node scripts/deploy/evening-readiness-audit.mjs");
    }
  });

  it("retains audit, canonical history and pre/postmigration reads when selecting the native transport", () => {
    expect(read("scripts/deploy/evening-readiness-audit.mjs")).toContain("if (enabledSessionReads(env)) return sessionReadQuery(sql, env, request);");
    expect(read("scripts/deploy/repair-portal-hotfix-history.mjs")).toContain("sessionReadQuery(hotfixProofQuery)");
    const preflight = read("scripts/deploy/redesign-preflight.mjs");
    expect(preflight).toContain("path==='/database/query' && enabledSessionReads(process.env)");
    expect(preflight).toContain("PREFLIGHT_NATIVE_READ_ONLY_REQUIRED");
    expect(read("scripts/deploy/redesign-postmigration.mjs")).toContain("preservationManagementRequest(before.catalog,before.worldPolicyInitialization)");
    expect(read("scripts/deploy/redesign-postmigration.mjs")).toContain("EXISTING_DATA_CHANGED_REQUIRES_RECONCILIATION");
  });

  it("uses native reads only for actor selection while measuring the actual PostgREST RPCs within their original limits", () => {
    const source = read("scripts/deploy/check-startregie-reads.mjs");
    expect(source).toContain("enabledSessionReads(env) ? await sessionReadQuery(ACTOR_QUERY, env, request)");
    expect(source.match(/sessionReadQuery\(/g)).toHaveLength(1);
    const rpc = source.slice(source.indexOf("async function rpc("), source.indexOf("const checks = []"));
    expect(rpc).toContain("/rest/v1/rpc/${name}");
    expect(rpc).toContain("if (!RPCS.has(name))");
    expect(rpc).not.toContain("sessionReadQuery");
    expect(source).toContain('new Set(["admin_startregie_snapshot", "admin_startregie_publication_readiness"])');
    expect(source).toContain("AbortSignal.timeout(20_000)");
    expect(rpc).toContain("durationMs >= 10_000");
    expect(source).toContain("attempt <= 3");
    expect(source).toContain("REAL_PRODUCTION_GROUPS_REQUIRED");
    expect(source).toContain('transport: "PostgREST"');
  });
});
