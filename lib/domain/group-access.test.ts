import { describe, expect, it } from "vitest";
import { groupAccessDenied, participantAccessKey } from "./group-access";

describe("changing a family's private group scope", () => {
  it("detects a moved family while retaining independent house and viewer scopes", () => {
    const independent = [{ key: "homeowner", portalId: "own-gate" }, { key: "viewer", groupId: "independent-group", accessId: "viewer-access" }];
    const before = [{ key: "walker", groupId: "old-group" }, ...independent];
    expect(participantAccessKey(before)).not.toBe(participantAccessKey([{ key: "walker", groupId: "new-group" }, ...independent]));
    expect(participantAccessKey(before)).toBe(participantAccessKey([...before].reverse()));
  });

  it.each([{ code: "42501" }, { message: "NOT_AUTHORIZED" }, { code: "PGRST301" }, { code: "P0002" }])("does not reuse an old private snapshot after a server denial: %j", error => {
    expect(groupAccessDenied(error)).toBe(true);
  });

  it("allows the existing offline fallback for a transport failure", () => {
    expect(groupAccessDenied({ code: "PGRST000", message: "Connection unavailable" })).toBe(false);
  });
});
