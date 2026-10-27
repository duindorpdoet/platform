import { describe, expect, it } from "vitest";
import { installedStagingHistory, missingInstalledFiles, STAGING_INSTALLED_MIGRATIONS, HOTFIX_BRANCH, GROUP_OPERATIONS_BRANCH, PLANBOARD_BRANCH, REGISTRATION_STATUS_BRANCH } from "./staging-installed-history.mjs";

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
  it("does not permit missing migration history on production or other branches", () => {
    for (const input of [{ ...context, APP_ENVIRONMENT: "production" }, { ...context, GITHUB_REF: "refs/heads/main" }, {}]) {
      expect(installedStagingHistory(input)).toEqual([]);
      expect(() => missingInstalledFiles([], [Object.keys(STAGING_INSTALLED_MIGRATIONS)[0].split("_")[0]], input)).toThrow();
    }
  });
});
