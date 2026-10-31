import { execFile } from "node:child_process";
import { statfs } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

function command(name, args, timeoutMs) {
  return new Promise(resolve => {
    // Only fixed local --version commands are executed. Do not pass database
    // credentials, connection options, Docker contexts or inherited secrets.
    execFile(name, args, { timeout: timeoutMs, killSignal: "SIGKILL", maxBuffer: 4096, env: { PATH: process.env.PATH, LANG: "C", LC_ALL: "C" } },
      (error, stdout) => resolve({ available: !error, stdout: error ? "" : stdout }));
  });
}

/** Existing runner capabilities only; no installation, database or network. */
export async function runVpsCapabilities(env = process.env, execute = command, filesystem = path => statfs(path, { bigint: true })) {
  if (env.DIAGNOSTIC_VPS_CAPABILITIES !== "true" || env.APP_ENVIRONMENT !== "production" || env.GITHUB_EVENT_NAME !== "workflow_dispatch"
    || env.GITHUB_REPOSITORY !== "duindorpdoet/platform" || env.GITHUB_REF !== "refs/heads/production" || !/^[a-f0-9]{40}$/.test(env.GITHUB_SHA ?? "")
    || env.RUNNER_NAME !== "dg-sites-vps-01-duindorphalloweenprod-01" || !env.GITHUB_WORKSPACE?.startsWith("/srv/sites/duindorphalloweenprod/actions-runner/_work/")) throw new Error("VPS_CAPABILITY_BOUNDARY");
  async function version(name) {
    try {
      const result = await execute(name, ["--version"], 3000);
      const parsed = result.available && typeof result.stdout === "string" && result.stdout.match(new RegExp(`^${name} \\(PostgreSQL\\) (\\d+(?:\\.\\d+){1,2})(?: [^\\r\\n]*)?\\s*$`));
      return { available: Boolean(result.available), version: parsed ? parsed[1] : null };
    } catch { return { available: false, version: null }; }
  }
  async function free(path) {
    try {
      const value = await filesystem(path), bytes = value.bavail * value.bsize;
      return typeof bytes === "bigint" && bytes >= 0n && bytes <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(bytes) : null;
    } catch { return null; }
  }
  const [psql, pg_dump, pg_restore, workspaceAvailableBytes, tempAvailableBytes, dockerServerReachable] = await Promise.all([
    version("psql"), version("pg_dump"), version("pg_restore"), free(env.GITHUB_WORKSPACE), free(env.RUNNER_TEMP ?? tmpdir()),
    execute("docker", ["--host", "unix:///var/run/docker.sock", "version", "--format", "{{.Server.Version}}"], 5000).then(result => result.available === true, () => false),
  ]);
  return { diagnostic: "production-vps-local-capabilities", scope: "VPS_CLIENT", databaseAccessed: false, sqlSent: false,
    tools: { psql, pg_dump, pg_restore }, workspaceAvailableBytes, tempAvailableBytes, dockerServerReachable };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  runVpsCapabilities().then(value => console.log(JSON.stringify(value))).catch(() => { console.error("VPS_CAPABILITY_BOUNDARY"); process.exitCode = 1; });
}
