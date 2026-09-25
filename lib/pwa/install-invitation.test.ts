import { describe, expect, it } from "vitest";
import { installInviteStorageKey, localDateKey, shouldShowInstallInvite } from "./install-invitation";

describe("PWA installation invitation", () => {
  it("uses the local calendar day and account in its key", () => {
    const date = new Date(2026, 9, 31, 23, 59);
    expect(localDateKey(date)).toBe("2026-10-31");
    expect(installInviteStorageKey("user-a", date)).toBe("poorten:pwa-invite:user-a:2026-10-31");
  });

  it("shows at most once per account and device each day", () => {
    const date = new Date(2026, 9, 31, 12);
    const values = new Map<string, string>();
    const storage = { getItem: (key: string) => values.get(key) ?? null };
    expect(shouldShowInstallInvite(storage, "user-a", date)).toBe(true);
    values.set(installInviteStorageKey("user-a", date), "shown");
    expect(shouldShowInstallInvite(storage, "user-a", date)).toBe(false);
    expect(shouldShowInstallInvite(storage, "user-b", date)).toBe(true);
    expect(shouldShowInstallInvite(storage, "user-a", new Date(2026, 10, 1, 12))).toBe(true);
  });
});
