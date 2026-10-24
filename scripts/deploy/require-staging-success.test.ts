import { spawnSync } from "node:child_process";
import { describe, expect, it } from "vitest";

function promote(workflowPassed: boolean, exactSha = true, deploymentPassed = true, environmentPassed = true) {
  return spawnSync(process.execPath, ["--input-type=module", "-e", `
    globalThis.fetch = async (input) => {
      const url = String(input);
      let body;
      if (url.includes('/actions/workflows/')) {
        body = {workflow_runs:[{id:7,head_sha:${exactSha ? 'process.env.GITHUB_SHA' : '"wrong-sha"'},head_branch:'staging',conclusion:${JSON.stringify(workflowPassed ? "success" : "failure")}}]};
      } else if (url.includes('/jobs?')) body = {jobs:[{name:'Dedicated staging runner maintenance (no deployment)',conclusion:'success'},{name:'Validate, migrate, deploy and accept',conclusion:${JSON.stringify(deploymentPassed ? 'success' : 'skipped')}}]};
      else if (url.includes('/statuses')) body = [{state:${JSON.stringify(environmentPassed ? 'success' : 'failure')}}];
      else body = [{id:1}];
      return new Response(JSON.stringify(body));
    };
    await import('./scripts/deploy/require-staging-success.mjs');
  `], {
    encoding: "utf8",
    env: { ...process.env, GITHUB_TOKEN: "test-only", GITHUB_REPOSITORY: "test/repo", GITHUB_SHA: "a".repeat(40) },
    timeout: 5000,
  });
}

describe("production staging workflow gate", () => {
  it("rejects a successful deployment when mailbox acceptance failed", () => {
    const result = promote(false);
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("mailbox acceptance or an explicitly selected dispatch waiver");
  });
  it("rejects success for another revision", () => {
    expect(promote(true, false).status).not.toBe(0);
  });
  it("rejects a successful maintenance run whose deployment job was skipped", () => {
    const result = promote(true,true,false);
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("Maintenance alone is not a deployment");
  });
  it("rejects a successful workflow without successful staging deployment status", () => {
    expect(promote(true,true,true,false).status).not.toBe(0);
  });
  it("accepts a successful full staging workflow and deployment on the exact revision", () => {
    const result = promote(true);
    expect(result.status, result.stderr).toBe(0);
  });
});
