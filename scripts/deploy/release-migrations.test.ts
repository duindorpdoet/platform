import {readFileSync,readdirSync} from "node:fs";
import {describe,expect,it} from "vitest";
import {assertReviewedReleaseMigrations,REVIEWED_RELEASE_MIGRATIONS,reviewedRepositoryMigrations} from "./release-migrations.mjs";
describe("the signed restore proof covers the entire reviewed release",()=>{
  it("matches the exact ordered repository expand set",()=>{
    const actual=reviewedRepositoryMigrations(readdirSync("supabase/migrations").filter(file=>file.endsWith(".sql")));
    expect(actual).toEqual(REVIEWED_RELEASE_MIGRATIONS);
    for (const file of actual) expect(readFileSync(`supabase/migrations/${file}`,"utf8").length).toBeGreaterThan(100);
  });
  it("includes the reviewed function-only coverage objective salt without a data waiver",()=>{
    expect(REVIEWED_RELEASE_MIGRATIONS.at(-1)).toBe("20261030153823_all_active_route_objective_hash.sql");
    const migration=readFileSync("supabase/migrations/20261030153823_all_active_route_objective_hash.sql","utf8");
    expect(migration).toContain("'routeObjective','all-active-coverage-v1'");
    expect(migration).toContain("app_private.joint_route_source_hash_before_v3(_event)");
    expect(migration).not.toMatch(/\b(?:insert|update|delete|truncate|alter\s+table)\b/i);
  });
  it("rejects an incomplete, duplicated, reordered or unreviewed migration proof",()=>{
    for (const proof of [REVIEWED_RELEASE_MIGRATIONS.slice(1),[...REVIEWED_RELEASE_MIGRATIONS,REVIEWED_RELEASE_MIGRATIONS[0]],
      [...REVIEWED_RELEASE_MIGRATIONS].reverse(),[...REVIEWED_RELEASE_MIGRATIONS,"20261024000000_unreviewed.sql"]]) {
      expect(()=>assertReviewedReleaseMigrations(proof)).toThrow("REVIEWED_MIGRATION_SET_CHANGED");
    }
  });
  it("cannot silently omit a future pending file because its date differs",()=>{
    expect(()=>reviewedRepositoryMigrations([...REVIEWED_RELEASE_MIGRATIONS,"20261024000000_pending.sql"])).toThrow();
  });
});
