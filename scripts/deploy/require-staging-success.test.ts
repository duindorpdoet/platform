import { spawnSync } from "node:child_process";
import { describe, expect, it } from "vitest";

function promote(workflowPassed: boolean, exactSha = true) {
  return spawnSync(process.execPath, ["--input-type=module", "-e", `
    globalThis.fetch = async (input) => {
      const url = String(input);
      let body;
      if (url.includes('/actions/workflows/')) {
        body = {workflow_runs:[{head_sha:${exactSha ? 'process.env.GITHUB_SHA' : '"wrong-sha"'},head_branch:'staging',conclusion:${JSON.stringify(workflowPassed ? "success" : "failure")}}]};
      } else if (url.includes('/statuses')) body = [{state:'success'}];
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

describe("production mail acceptance gate", () => {
  it("rejects a successful deployment when mailbox acceptance failed", () => {
    const result = promote(false);
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("including real mailbox acceptance");
  });
  it("rejects success for another revision", () => {
    expect(promote(true, false).status).not.toBe(0);
  });
  it("accepts a successful full staging workflow and deployment on the exact revision", () => {
    const result = promote(true);
    expect(result.status, result.stderr).toBe(0);
  });
});
