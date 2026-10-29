import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { spawn } = vi.hoisted(() => ({ spawn: vi.fn() }));
vi.mock("node:child_process", async (importOriginal) => ({
  ...await importOriginal<typeof import("node:child_process")>(),
  spawn,
}));

import { parallelSql } from "../scripts/acceptance/together-fixtures.mjs";

function fixtureProcess() {
  const child = Object.assign(new EventEmitter(), {
    stdin: { end: vi.fn() },
    stdout: new PassThrough(),
    stderr: new PassThrough(),
  });
  spawn.mockReturnValue(child);
  return child;
}

beforeEach(() => {
  vi.stubEnv("SUPABASE_URL", "http://127.0.0.1:54321");
  vi.stubEnv("TOGETHER_TEST_DB_CONTAINER", "supabase_db_output_unit");
});
afterEach(() => {
  vi.unstubAllEnvs();
  vi.clearAllMocks();
});

describe("parallel SQL fixture output", () => {
  it("waits for complete stdout after process exit", async () => {
    const child = fixtureProcess();
    const result = parallelSql("select 'SL-2026-ABC234';");
    let settled = false;
    void result.then(() => { settled = true; }, () => { settled = true; });
    child.emit("exit", 0);
    await Promise.resolve();
    expect(settled).toBe(false);
    child.stdout.write("SL-2026-");
    child.stdout.write("ABC234\n");
    child.emit("close", 0);
    await expect(result).resolves.toBe("SL-2026-ABC234");
    expect(child.stdin.end).toHaveBeenCalledExactlyOnceWith("select 'SL-2026-ABC234';");
  });

  it("keeps stderr arriving after a failing process exit", async () => {
    const child = fixtureProcess();
    const result = parallelSql("select invalid_fixture();");
    let settled = false;
    void result.then(() => { settled = true; }, () => { settled = true; });
    child.emit("exit", 3);
    await Promise.resolve();
    expect(settled).toBe(false);
    child.stderr.write("ERROR: invalid fixture statement\n");
    child.emit("close", 3);
    await expect(result).rejects.toThrow("ERROR: invalid fixture statement");
  });

  it("still rejects process startup errors", async () => {
    const child = fixtureProcess();
    const result = parallelSql("select 1;");
    child.emit("error", new Error("fixture process failed to start"));
    await expect(result).rejects.toThrow("fixture process failed to start");
  });
});
