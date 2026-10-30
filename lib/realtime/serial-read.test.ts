import { describe, expect, it, vi } from "vitest";
import { createSerialRead } from "./serial-read";

const deferred = () => {
  let resolve!: (value: boolean) => void;
  const promise = new Promise<boolean>(done => { resolve = done; });
  return { promise, resolve };
};

describe("publication preflight read pressure", () => {
  it("shares repeated checks of the same stored revisions", async () => {
    const gate = createSerialRead(), first = deferred(), read = vi.fn(() => first.promise);
    const a = gate.run("revisions-1", read), b = gate.run("revisions-1", read);
    expect(a).toBe(b);
    await Promise.resolve();
    expect(read).toHaveBeenCalledTimes(1);
    first.resolve(false);
    await expect(a).resolves.toBe(false);
    await expect(b).resolves.toBe(false);
  });
  it("serializes changed revision checks instead of returning an older successful result", async () => {
    const gate = createSerialRead(), first = deferred(), old = vi.fn(() => first.promise), current = vi.fn(async () => false);
    const a = gate.run("revisions-1", old), b = gate.run("revisions-2", current);
    await Promise.resolve();
    expect(current).not.toHaveBeenCalled();
    first.resolve(true);
    await expect(a).resolves.toBe(true);
    await expect(b).resolves.toBe(false);
    expect(current).toHaveBeenCalledTimes(1);
  });
  it("allows a fresh read after rejection and does not reuse a failed preflight", async () => {
    const gate = createSerialRead();
    await expect(gate.run("revisions-1", async () => { throw new Error("timeout"); })).rejects.toThrow("timeout");
    await expect(gate.run("revisions-1", async () => false)).resolves.toBe(false);
  });
});
