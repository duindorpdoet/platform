import { describe, expect, it } from "vitest";
import { portalEditorSystemNumber, portalNumberIsEditable } from "./portal-editor-identity";

describe("portal identity when reopening maintenance drafts", () => {
  const approved = { lifecycleStatus: "approved", approvalStatus: "approved", systemCode: "P-38" };

  it("restores P-38 from the approved record when an old maintenance draft has an empty number", () => {
    expect(portalEditorSystemNumber(approved, { systemNumber: null })).toBe("38");
    expect(portalEditorSystemNumber(approved, { systemNumber: "" })).toBe("38");
    expect(portalNumberIsEditable(approved)).toBe(false);
  });

  it("ignores stale proposed numbers for approved, active and archived portals", () => {
    for (const lifecycleStatus of ["approved", "active", "archived"]) {
      const portal = { ...approved, lifecycleStatus };
      expect(portalEditorSystemNumber(portal, { systemNumber: 99 })).toBe("38");
      expect(portalNumberIsEditable(portal)).toBe(false);
    }
  });

  it("does not unlock an approved number just because a saved draft has a concept lifecycle", () => {
    const portal = { ...approved, lifecycleStatus: "concept" };
    expect(portalNumberIsEditable(portal)).toBe(false);
    expect(portalEditorSystemNumber(portal, { systemNumber: null })).toBe("38");
  });

  it("preserves an intentional proposal or automatic allocation before approval", () => {
    for (const lifecycleStatus of ["concept", "registered"]) {
      const portal = { ...approved, lifecycleStatus, approvalStatus: "draft" };
      expect(portalNumberIsEditable(portal)).toBe(true);
      expect(portalEditorSystemNumber(portal, { systemNumber: 42 })).toBe("42");
      expect(portalEditorSystemNumber(portal, { systemNumber: null })).toBe("");
      expect(portalEditorSystemNumber(portal)).toBe("38");
    }
  });
});
