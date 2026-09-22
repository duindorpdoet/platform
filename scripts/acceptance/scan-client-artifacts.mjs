import { lstat, readFile, readdir } from "node:fs/promises";
import { relative, resolve } from "node:path";

const workspace = process.cwd();
const roots = [".next/static", ".next/server/app", ".next/server/chunks", "public/sw.js"];
const checks = [
  { label: "SendGrid credential", pattern: /SG\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/ },
  { label: "fixture QR credential", pattern: /TEST-PORTAL-[0-9]{2}-TOKEN/ },
  { label: "fixture account password", pattern: /local-test-only/ },
];

for (const name of ["SENDGRID_API_KEY", "SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_SECRET_KEY", "CRON_SECRET", "PORTAL_CODE_PEPPER", "ABUSE_HASH_SECRET", "SEND_EMAIL_HOOK_SECRET"]) {
  const value = process.env[name];
  if (value && value.length >= 12) checks.push({ label: `${name} value`, pattern: new RegExp(value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")) });
}

async function filesAt(path) {
  const info = await lstat(path);
  if (info.isFile()) return [path];
  const entries = await readdir(path, { withFileTypes: true });
  const nested = await Promise.all(entries.filter((entry) => !entry.isSymbolicLink()).map((entry) => filesAt(resolve(path, entry.name))));
  return nested.flat();
}

const files = [];
for (const root of roots) {
  try { files.push(...await filesAt(resolve(workspace, root))); } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

for (const file of files) {
  const contents = await readFile(file, "utf8");
  for (const check of checks) {
    check.pattern.lastIndex = 0;
    if (check.pattern.test(contents)) throw new Error(`${check.label} found in client/build artifact ${relative(workspace, file)}`);
  }
}

console.log(JSON.stringify({ status: "pass", checks: ["PRIV-08"], filesScanned: files.length }));
