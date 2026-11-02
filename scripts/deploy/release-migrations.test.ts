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
    expect(REVIEWED_RELEASE_MIGRATIONS).toContain("20261030153823_all_active_route_objective_hash.sql");
    const migration=readFileSync("supabase/migrations/20261030153823_all_active_route_objective_hash.sql","utf8");
    expect(migration).toContain("'routeObjective','all-active-coverage-v1'");
    expect(migration).toContain("app_private.joint_route_source_hash_before_v3(_event)");
    expect(migration).not.toMatch(/\b(?:insert|update|delete|truncate|alter\s+table)\b/i);
  });
  it("preserves the reviewed route fixes before the additive Duinpad release",()=>{
    expect(REVIEWED_RELEASE_MIGRATIONS.slice(-13)).toEqual([
      "20261030182243_p12_hard_close_and_75_minute_routes.sql",
      "20261030231652_bound_startregie_snapshot_reads.sql",
      "20261030233039_materialize_route_source_contexts.sql",
      "20261031143846_duinpad_actor_access.sql",
      "20261031143910_duinpad_finale_evening.sql",
      "20261031143920_duinpad_checkpoints_and_show_attempts.sql",
      "20261101191738_event_evening_central_closure.sql",
      "20261101191801_event_closure_house_thanks.sql",
      "20261101220535_portal_actual_impact.sql",
      "20261101220654_house_thanks_custom_owner_mail.sql",
      "20261101221956_portal_certificate_team_campaign.sql",
      "20261101230529_portal_registered_certificate_impact.sql",
      "20261102074430_portal_closed_room_thanks_access.sql",
    ]);
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
