if (!process.env.SUPABASE_ACCESS_TOKEN || !process.env.SUPABASE_PROJECT_REF) {
  throw new Error("Supabase advisor credentials are missing.");
}

const response = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_REF}/advisors/security`, {
  headers: {
    Accept: "application/json",
    Authorization: `Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`,
  },
});
if (!response.ok) throw new Error(`Supabase security advisor request failed (${response.status}).`);
const payload = await response.json();
const lints = Array.isArray(payload.lints) ? payload.lints : [];
const reportable = lints.filter((lint) => ["ERROR", "WARN"].includes(String(lint.level).toUpperCase()));

for (const lint of reportable) {
  const entity = lint.metadata?.entity ?? lint.metadata?.name ?? "project";
  console.log(`${String(lint.level).toUpperCase()}: ${lint.name} (${entity})`);
}
const errors = reportable.filter((lint) => String(lint.level).toUpperCase() === "ERROR");
if (errors.length) throw new Error(`Supabase security advisor returned ${errors.length} error finding(s).`);
console.log(`Supabase security advisor gate passed (${reportable.length} warning-level finding(s)).`);
