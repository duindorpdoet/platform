import { describe, expect, it } from "vitest";
import { attendanceSummary, reconcileAttendance } from "./attendance-check";

describe("group attendance check", () => {
  it("requires an explicit decision for every current child", () => {
    expect(attendanceSummary(["a", "b"], { a: "present" })).toMatchObject({ checked: 1, total: 2, complete: false, canStart: false });
    expect(attendanceSummary(["a", "b"], { a: "present", b: "absent" })).toMatchObject({ checked: 2, presentIds: ["a"], absent: 1, complete: true, canStart: true });
  });

  it("does not allow a run with zero present children", () => {
    expect(attendanceSummary(["a", "b"], { a: "absent", b: "absent" })).toMatchObject({ complete: true, canStart: false });
  });

  it("drops stale decisions and never selects new roster members", () => {
    expect(reconcileAttendance(["a", "c"], { a: "present", b: "absent" })).toEqual({ a: "present" });
  });
});
