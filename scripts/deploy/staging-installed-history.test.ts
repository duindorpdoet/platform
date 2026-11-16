import { describe, expect, it } from "vitest";
import { installedStagingHistory, installedStagingSourceRevision, STAGING_SOURCE_REVISION, FRIGHTNIGHT_STAGING_SOURCE_REVISION, missingInstalledFiles, STAGING_INSTALLED_MIGRATIONS, HOTFIX_BRANCH, GROUP_OPERATIONS_BRANCH, PLANBOARD_BRANCH, REGISTRATION_STATUS_BRANCH, UPDATES_HTML_BRANCH } from "./staging-installed-history.mjs";

const context = { APP_ENVIRONMENT: "staging", GITHUB_REF: `refs/heads/${HOTFIX_BRANCH}` };
describe("isolated hotfix staging history", () => {
  it("recognizes only the pinned already installed staging versions", () => {
    const first = Object.keys(STAGING_INSTALLED_MIGRATIONS)[0];
    expect(missingInstalledFiles(["20260920160812_initial_platform.sql"], ["20260920160812", first.split("_")[0]], context)).toEqual([first]);
    expect(missingInstalledFiles([first], [first.split("_")[0]], context)).toEqual([]);
    expect(() => missingInstalledFiles([], ["20271025000000"], context)).toThrow("LIVE_MIGRATION_HISTORY_DRIFT");
  });
  it("preserves the same pinned history for the group operations release", () => {
    expect(installedStagingHistory({ ...context, GITHUB_REF: `refs/heads/${GROUP_OPERATIONS_BRANCH}` })).toEqual(Object.keys(STAGING_INSTALLED_MIGRATIONS));
  });
  it("preserves the same pinned history for the planboard release", () => {
    expect(installedStagingHistory({ ...context, GITHUB_REF: `refs/heads/${PLANBOARD_BRANCH}` })).toEqual(Object.keys(STAGING_INSTALLED_MIGRATIONS));
  });
  it("preserves the same pinned history for the registration status release", () => {
    expect(installedStagingHistory({ ...context, GITHUB_REF: `refs/heads/${REGISTRATION_STATUS_BRANCH}` })).toEqual(Object.keys(STAGING_INSTALLED_MIGRATIONS));
  });
  it("preserves installed experiments on staging without promoting them to production", () => {
    expect(installedStagingHistory({ ...context, GITHUB_REF: "refs/heads/staging" })).toEqual(Object.keys(STAGING_INSTALLED_MIGRATIONS));
  });
  it('recognizes all five installed FrightNight versions only as staging history for the isolated update hotfix',()=>{
    const branch={...context,GITHUB_REF:`refs/heads/${UPDATES_HTML_BRANCH}`};
    const files=Object.keys(STAGING_INSTALLED_MIGRATIONS).filter(file=>file.includes('frightnight'));
    expect(files).toHaveLength(5);expect(Object.keys(STAGING_INSTALLED_MIGRATIONS)).toHaveLength(18);
    expect(missingInstalledFiles([],files.map(file=>file.split('_')[0]),branch)).toEqual(files);
    expect(installedStagingHistory({...branch,APP_ENVIRONMENT:'production'})).toEqual([]);
    expect(()=>missingInstalledFiles([],['20261103099999'],branch)).toThrow('LIVE_MIGRATION_HISTORY_DRIFT');
  });
  it("retains the exact original source for old history and the exact FrightNight source for its five installed files", () => {
    for (const file of Object.keys(STAGING_INSTALLED_MIGRATIONS)) {
      expect(installedStagingSourceRevision(file)).toBe(file.includes("_frightnight_2027_") ? FRIGHTNIGHT_STAGING_SOURCE_REVISION : STAGING_SOURCE_REVISION);
    }
    expect(STAGING_SOURCE_REVISION).toBe("a0263258c03a5aaed5c08445c461aed3f3206756");
    expect(FRIGHTNIGHT_STAGING_SOURCE_REVISION).toBe("9b0b215f922766f6c69db67dc4f25a37d4a95c9e");
    expect(() => installedStagingSourceRevision("20261103099999_frightnight_2027_unknown.sql")).toThrow("UNREVIEWED_STAGING_HISTORY_SOURCE");
  });
  it("does not permit missing migration history on production or other branches", () => {
    for (const input of [{ ...context, APP_ENVIRONMENT: "production" }, { ...context, GITHUB_REF: "refs/heads/main" }, {}]) {
      expect(installedStagingHistory(input)).toEqual([]);
      expect(() => missingInstalledFiles([], [Object.keys(STAGING_INSTALLED_MIGRATIONS)[0].split("_")[0]], input)).toThrow();
    }
  });
});
