import {describe,expect,it} from "vitest";
import {amsterdamDateTimeInput,amsterdamInputToIso} from "./amsterdam";
describe("Amsterdam event wall times",()=>{
  it("converts independently from the machine timezone",()=>{
    expect(amsterdamInputToIso("2026-10-31T17:30")).toBe("2026-10-31T16:30:00.000Z");
    expect(amsterdamDateTimeInput("2026-10-31T16:30:00.000Z")).toBe("2026-10-31T17:30");
  });
  it.each(["2026-03-29T02:30","2026-10-25T02:30","2026-02-30T17:30","bad",""])("rejects missing, ambiguous or invalid time %s",value=>expect(amsterdamInputToIso(value)).toBeNull());
});
