import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { enabledSessionReads, sessionReadQuery } from "./production-read-query.mjs";
import { hotfixProofQuery, hotfixRepairActions } from "./repair-portal-hotfix-history.mjs";
import { AUDIT_QUERY } from "./evening-readiness-audit.mjs";
import { releaseMetadataQuery } from "./redesign-reconciliation.mjs";
import { runProductionDirectMigrationDryRun } from "./migrate-production-direct.mjs";

const fail = code => { throw new Error(`PRODUCTION_OWNER_PROOF_${code}`); };

/** Fixed production inspections and a hardcoded CLI dry run; no deployment. */
export async function proveProductionOwnerReads(env = process.env) {
  if (env.GITHUB_EVENT_NAME !== "workflow_dispatch" || env.GITHUB_WORKFLOW !== "Read-only production VPS client proof"
    || env.GITHUB_REF !== "refs/heads/production" || env.APP_ENVIRONMENT !== "production"
    || env.RUNNER_NAME !== "dg-sites-vps-01-duindorphalloweenprod-01" || env.RELEASE_READ_CLIENT !== "libpq"
    || env.RELEASE_READ_TRANSPORT !== "session-pooler" || env.MIGRATION_CONNECT_PROOF !== "true"
    || !env.RUNNER_TEMP || !enabledSessionReads(env)) fail("ENVIRONMENT_BOUNDARY");
  const report = { diagnostic: "production-vps-owner-read-and-migration-dry-run", revision: env.GITHUB_SHA,
    status: "running", readOnly: true, changedRows: 0, messagesSent: 0, phases: [] };
  let activePhase = "canonical-function-trigger-draft-history";
  let started = performance.now();
  try {
    console.log(JSON.stringify({ ownerProofPhase: activePhase, status: "started" }));
    const rows = await sessionReadQuery(hotfixProofQuery, env);
    if (rows.length !== 1 || hotfixRepairActions(rows[0], "production").length !== 0) fail("CANONICAL_HISTORY_REQUIRED");
    report.phases.push({ phase: "canonical-function-trigger-draft-history", durationMs: Math.round(performance.now() - started), passed: true });
    console.log(JSON.stringify(report.phases.at(-1)));
    activePhase = "saved-production-groups-and-preservation-checkpoint";
    started = performance.now();
    console.log(JSON.stringify({ ownerProofPhase: activePhase, status: "started" }));
    const auditRows = await sessionReadQuery(AUDIT_QUERY, env);
    const audit = auditRows?.[0]?.audit;
    if (auditRows.length !== 1 || !Number.isSafeInteger(audit?.counts?.groups) || audit.counts.groups < 1
      || !Array.isArray(audit.groups) || audit.groups.length !== audit.counts.groups
      || !["settings", "appointments", "routesAndRuns"].every(name => /^[a-f0-9]{32}$/.test(audit.checkpoint?.[name] ?? ""))) fail("REAL_GROUP_AUDIT_REQUIRED");
    report.phases.push({ phase: "saved-production-groups-and-preservation-checkpoint", durationMs: Math.round(performance.now() - started), passed: true, groups: audit.counts.groups });
    console.log(JSON.stringify(report.phases.at(-1)));
    activePhase = "production-preservation-metadata";
    started = performance.now();
    console.log(JSON.stringify({ ownerProofPhase: activePhase, status: "started" }));
    const metadataRows = await sessionReadQuery(releaseMetadataQuery(), env);
    const metadata = metadataRows?.[0]?.metadata;
    if (metadataRows.length !== 1 || !Array.isArray(metadata?.migrationHistory) || !Array.isArray(metadata.mailEventIds)
      || !/^\d+$/.test(metadata.cronBoundary ?? "")) fail("PRESERVATION_METADATA_REQUIRED");
    report.phases.push({ phase: "production-preservation-metadata", durationMs: Math.round(performance.now() - started), passed: true, migrationRecords: metadata.migrationHistory.length });
    console.log(JSON.stringify(report.phases.at(-1)));
    activePhase = "pinned-cli-migration-dry-run";
    started = performance.now();
    console.log(JSON.stringify({ ownerProofPhase: activePhase, status: "started" }));
    const dryRun = await runProductionDirectMigrationDryRun(env);
    if (dryRun.status !== "SUCCESS" || dryRun.dryRun !== true) fail("MIGRATION_DRY_RUN_REQUIRED");
    report.phases.push({ phase: "pinned-cli-migration-dry-run", durationMs: Math.round(performance.now() - started), passed: true, migrations: dryRun.migrations });
    console.log(JSON.stringify(report.phases.at(-1)));
    report.status = "passed";
    return report;
  } catch (error) {
    report.status = "failed";
    report.phases.push({ phase: activePhase, durationMs: Math.round(performance.now() - started), passed: false,
      error: /^(?:RELEASE_READ|HOTFIX|PRODUCTION_DIRECT_MIGRATION|PRODUCTION_OWNER_PROOF)_[A-Z0-9_]+$/.test(error?.message ?? "") ? error.message : "PRODUCTION_OWNER_PROOF_FAILED" });
    throw error;
  } finally {
    const directory = join(env.RUNNER_TEMP, "duindorp-vps-owner-proof");
    await mkdir(directory, { recursive: true, mode: 0o700 });
    await writeFile(join(directory, "report.json"), JSON.stringify(report, null, 2) + "\n", { flag: "wx", mode: 0o600 });
    console.log(JSON.stringify(report));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  proveProductionOwnerReads().catch(error => {
    console.error(/^(?:RELEASE_READ|HOTFIX|PRODUCTION_DIRECT_MIGRATION|PRODUCTION_OWNER_PROOF)_[A-Z0-9_]+$/.test(error?.message ?? "") ? error.message : "PRODUCTION_OWNER_PROOF_FAILED");
    process.exitCode = 1;
  });
}
