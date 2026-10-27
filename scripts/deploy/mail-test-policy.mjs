import { appendFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

export function mailTestPolicy(context, now = Date.now()) {
  const sha = context.GITHUB_SHA;
  if (!/^[a-f0-9]{40}$/.test(sha ?? "")) throw new Error("RELEASE_SHA_REQUIRED");
  if (context.GITHUB_EVENT_NAME === "workflow_dispatch" && context.SKIP_MAIL_TESTS_REQUESTED === "true") {
    return { skip: true, source: "explicit-dispatch", sha, reason: "Operator explicitly selected skip_mail_tests for this release run." };
  }
  if (context.MAIL_TEST_WAIVER_SHA !== sha) return { skip: false, source: "default", sha, reason: "Normal mail acceptance remains enabled." };
  if (context.GITHUB_REPOSITORY !== "duindorpdoet/platform") throw new Error("MAIL_WAIVER_REPOSITORY_MISMATCH");
  const expires = Date.parse(context.MAIL_TEST_WAIVER_EXPIRES_AT ?? "");
  if (!Number.isFinite(expires) || expires <= now || expires > now + 72 * 60 * 60 * 1000) throw new Error("MAIL_WAIVER_EXPIRED_OR_UNBOUNDED");
  if (!context.MAIL_TEST_WAIVER_REASON?.trim()) throw new Error("MAIL_WAIVER_REASON_REQUIRED");
  return { skip: true, source: "exact-release-sha", sha, reason: context.MAIL_TEST_WAIVER_REASON.replace(/[\r\n]/g, " ").slice(0, 500) };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const policy = mailTestPolicy(process.env);
  const line = `Mail tests ${policy.skip ? "SKIPPED" : "enabled"} for ${policy.sha} (${policy.source}): ${policy.reason}`;
  console.log(line);
  if (process.env.GITHUB_OUTPUT) await appendFile(process.env.GITHUB_OUTPUT, `skip_mail_tests=${policy.skip}\n`);
  if (process.env.GITHUB_STEP_SUMMARY) await appendFile(process.env.GITHUB_STEP_SUMMARY, `### Release mail-test policy\n\n${line}\n\n${policy.skip ? "No mail sends, OTP requests, mailbox polling, provider/hook runtime probes or delivery/webhook mail tests. Backup/restore, migrations, security, build and non-mail acceptance remain required." : "Normal release acceptance applies."}\n`);
}
