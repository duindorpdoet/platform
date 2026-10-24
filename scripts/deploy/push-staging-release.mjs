import { createHash } from "node:crypto";
import { readdir, writeFile, unlink } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { missingInstalledFiles, STAGING_INSTALLED_MIGRATIONS, STAGING_SOURCE_REVISION } from "./staging-installed-history.mjs";

// CLI history validation needs local files for already installed staging-only
// versions. Materialize their exact reviewed source only around `db push`.
// The backup, signed release list, tests and production tree contain only the
// targeted release. Unknown remote versions still stop the deployment.
const prepared = [];
try {
  const response = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_REF}/database/query`, {
    method: "POST", headers: { Authorization: `Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify({ read_only: true, query: "select version from supabase_migrations.schema_migrations order by version" }),
    signal: AbortSignal.timeout(60_000),
  });
  if (!response.ok) throw new Error(`STAGING_HISTORY_READ_${response.status}`);
  const installed = await response.json();
  const files = missingInstalledFiles(await readdir("supabase/migrations"), installed.map(row => row.version));
  for (const file of files) {
    const source = await fetch(`https://api.github.com/repos/${process.env.GITHUB_REPOSITORY}/contents/supabase/migrations/${file}?ref=${STAGING_SOURCE_REVISION}`, {
      headers: { Authorization: `Bearer ${process.env.GITHUB_TOKEN}`, Accept: "application/vnd.github+json" }, signal: AbortSignal.timeout(30_000),
    });
    if (!source.ok) throw new Error(`STAGING_SOURCE_READ_${source.status}`);
    const blob = await source.json(), bytes = Buffer.from(blob.content, "base64");
    if (blob.encoding !== "base64" || createHash("sha256").update(bytes).digest("hex") !== STAGING_INSTALLED_MIGRATIONS[file]) throw new Error("STAGING_SOURCE_HASH_MISMATCH");
    const path = `supabase/migrations/${file}`;
    await writeFile(path, bytes, { flag: "wx" }); prepared.push(path);
  }
  const result = spawnSync("pnpm", ["exec", "supabase", "db", "push", "--linked", "--include-all", "--yes"], { stdio: "inherit", timeout: 300_000 });
  if (result.status !== 0) throw new Error("STAGING_MIGRATION_FAILED");
} finally {
  for (const path of prepared) await unlink(path);
}
