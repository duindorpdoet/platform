import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, mkdir, readFile, writeFile, rm, symlink, chmod, link, lstat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { execFile } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CLIENT_IMAGE, CLIENT_VERSION, portableClientManifest, buildPortablePostgresClient, validatePortablePostgresClient } from "./portable-postgres-clients.mjs";

afterEach(() => vi.unstubAllEnvs());

describe("pinned user-space PostgreSQL17 clients", () => {
  it("pins the official image, exactly three wrappers and the complete independent ELF/loader/library hashes", () => {
    expect(CLIENT_IMAGE).toBe("public.ecr.aws/supabase/postgres@sha256:6942962433a569e87f228b4d4ab7e11db5deca64e43babb3a038443ad6c4f1bb");
    expect(CLIENT_VERSION).toBe("17.6");
    const manifest = portableClientManifest();
    expect(manifest.files).toHaveLength(26);
    expect(new Set(manifest.files.map(row => row.file)).size).toBe(26);
    expect(manifest.files.filter(row => row.file.startsWith("bin/")).map(row => row.file)).toEqual(["bin/pg_dump", "bin/pg_restore", "bin/psql"]);
    expect(manifest.files.some(row => row.file === "lib/ld-linux-x86-64.so.2")).toBe(true);
    expect(manifest.files.every(row => /^(?:bin|elf|lib)\/[A-Za-z0-9_.-]+$/.test(row.file) && row.bytes > 0 && /^[a-f0-9]{64}$/.test(row.sha256))).toBe(true);
    manifest.files[0].sha256 = "f".repeat(64);
    expect(portableClientManifest().files[0].sha256).not.toBe("f".repeat(64));
  });
  it("refuses unsafe roots before invoking Docker or activating executables", async () => {
    const execute = vi.fn();
    for (const path of ["", "/", "relative/path", "/tmp/private\0path"]) {
      await expect(buildPortablePostgresClient(path, execute)).rejects.toThrow("DIRECTORY_REQUIRED");
      await expect(validatePortablePostgresClient(path)).rejects.toThrow("DIRECTORY_REQUIRED");
    }
    expect(execute).not.toHaveBeenCalled();
  });
  it("never overwrites or removes an existing user directory", async () => {
    const directory = await mkdtemp(join(tmpdir(), "pg17-existing-")), execute = vi.fn();
    try {
      await writeFile(join(directory, "other-work"), "preserve");
      await expect(buildPortablePostgresClient(directory, execute)).rejects.toThrow("BUILD_FAILED");
      expect(existsSync(join(directory, "other-work"))).toBe(true); expect(execute).not.toHaveBeenCalled();
    } finally { await rm(directory, { recursive: true, force: true }); }
  });
  it("sanitizes preparation failure and removes only its newly created user directory", async () => {
    const parent = await mkdtemp(join(tmpdir(), "pg17-build-")), directory = join(parent, "client");
    const execute = vi.fn(async () => { throw new Error("PRIVATE_REGISTRY_PASSWORD"); });
    try {
      await expect(buildPortablePostgresClient(directory, execute)).rejects.toThrow(/^PORTABLE_PG_BUILD_FAILED$/);
      expect(execute).toHaveBeenCalledExactlyOnceWith(["pull", "--quiet", "--platform", "linux/amd64", CLIENT_IMAGE]);
      expect(existsSync(directory)).toBe(false);
    } finally { await rm(parent, { recursive: true, force: true }); }
  });
  it("requires an immutable canonical manifest rather than trusting artifact-provided hashes", async () => {
    const directory = await mkdtemp(join(tmpdir(), "pg17-manifest-"));
    try {
      await writeFile(join(directory, "manifest.json"), JSON.stringify({ ...portableClientManifest(), sourceImage: "PRIVATE_UNTRUSTED_IMAGE" }));
      await expect(validatePortablePostgresClient(directory)).rejects.toThrow("MANIFEST_MISMATCH");
    } finally { await rm(directory, { recursive: true, force: true }); }
  });
  it.each(["extra", "symlink", "writable"])("refuses %s artifact content before chmod or execution", async kind => {
    const directory = await mkdtemp(join(tmpdir(), "pg17-content-"));
    try {
      await writeFile(join(directory, "manifest.json"), JSON.stringify(portableClientManifest(), null, 2) + "\n");
      for (const subdir of ["bin", "elf", "lib"]) await mkdir(join(directory, subdir), { mode: 0o700 });
      if (kind === "extra") await writeFile(join(directory, "PRIVATE"), "other");
      if (kind === "symlink") { await rm(join(directory, "bin"), { recursive: true }); await symlink("/tmp", join(directory, "bin")); }
      if (kind === "writable") await chmod(directory, 0o777);
      await expect(validatePortablePostgresClient(directory)).rejects.toThrow(/UNEXPECTED_FILES|UNSAFE_FILESYSTEM/);
    } finally { await rm(directory, { recursive: true, force: true }); }
  });
  it("fails on missing pinned files without attempting any binary", async () => {
    const directory = await mkdtemp(join(tmpdir(), "pg17-incomplete-"));
    try {
      await writeFile(join(directory, "manifest.json"), JSON.stringify(portableClientManifest(), null, 2) + "\n");
      for (const subdir of ["bin", "elf", "lib"]) await mkdir(join(directory, subdir), { mode: 0o700 });
      await expect(validatePortablePostgresClient(directory)).rejects.toThrow("INCOMPLETE_FILES");
    } finally { await rm(directory, { recursive: true, force: true }); }
  });
  it("never chmods a hardlinked existing file outside the supplied bundle", async () => {
    const parent = await mkdtemp(join(tmpdir(), "pg17-hardlink-")), directory = join(parent, "client"), other = join(parent, "other-work");
    try {
      await mkdir(directory, { mode: 0o700 });
      await writeFile(other, JSON.stringify(portableClientManifest(), null, 2) + "\n", { mode: 0o644 });
      const before = (await lstat(other)).mode & 0o777;
      await link(other, join(directory, "manifest.json"));
      await expect(validatePortablePostgresClient(directory)).rejects.toThrow("UNSAFE_FILESYSTEM");
      expect((await lstat(other)).mode & 0o777).toBe(before);
    } finally { await rm(parent, { recursive: true, force: true }); }
  });

  it("uses the actual command runner with quiet pull so cold-layer progress cannot overflow its 4KB metadata bound", async () => {
    const parent = await mkdtemp(join(tmpdir(), "pg17-command-")), directory = join(parent, "client"), log = join(parent, "calls");
    try {
      await writeFile(join(parent, "docker"), `#!/bin/sh\nprintf '%s\\n' "$*" >> "$PG17_TEST_CALLS"\nif [ "$1" = pull ]; then\n  if [ "$2" = --quiet ]; then printf '%s\\n' 'sha256:fixture'; else head -c 8192 /dev/zero | tr '\\000' x; fi\n  exit 0\nfi\nprintf '%s\\n' invalid-container\n`, { mode: 0o700 });
      vi.stubEnv("PATH", parent + ":" + process.env.PATH); vi.stubEnv("PG17_TEST_CALLS", log);
      // The old runner's real execFile options fail on simulated cold-pull
      // progress even though this process would otherwise exit successfully.
      const oldFailure = await new Promise(resolve => execFile("docker", ["pull", "--platform", "linux/amd64", CLIENT_IMAGE],
        { timeout: 180000, killSignal: "SIGKILL", maxBuffer: 4096 }, error => resolve(error?.code)));
      expect(oldFailure).toBe("ERR_CHILD_PROCESS_STDIO_MAXBUFFER");
      // Reaching CREATE proves the real execFile pull completed rather than
      // failing at its output bound. Invalid ID stops before any copy/execute.
      await expect(buildPortablePostgresClient(directory)).rejects.toThrow(/^PORTABLE_PG_CONTAINER_ID_REQUIRED$/);
      expect((await readFile(log, "utf8")).trim().split("\n")).toEqual([
        `pull --platform linux/amd64 ${CLIENT_IMAGE}`,
        `pull --quiet --platform linux/amd64 ${CLIENT_IMAGE}`,
        `create --platform linux/amd64 --network none --entrypoint sh ${CLIENT_IMAGE} -c exit 0`,
      ]);
      expect(existsSync(directory)).toBe(false);
    } finally { await rm(parent, { recursive: true, force: true }); }
  });

  it.each(["overflow", "exit"])("reports the fixed pull failure class for actual command-runner %s without raw output or replay", async kind => {
    const parent = await mkdtemp(join(tmpdir(), "pg17-command-fail-")), directory = join(parent, "client"), log = join(parent, "calls");
    try {
      await writeFile(join(parent, "docker"), `#!/bin/sh\nprintf '%s\\n' "$1" >> "$PG17_TEST_CALLS"\n${kind === "overflow" ? "head -c 8192 /dev/zero | tr '\\000' x >&2; sleep 1" : "printf '%s\\n' PRIVATE_REGISTRY_CREDENTIAL_ERROR >&2; exit 17"}\n`, { mode: 0o700 });
      vi.stubEnv("PATH", parent + ":" + process.env.PATH); vi.stubEnv("PG17_TEST_CALLS", log);
      await expect(buildPortablePostgresClient(directory)).rejects.toThrow(new RegExp(`^PORTABLE_PG_DOCKER_PULL_${kind === "overflow" ? "OUTPUT_LIMIT" : "FAILED"}$`));
      expect(await readFile(log, "utf8")).toBe("pull\n");
      expect(existsSync(directory)).toBe(false);
    } finally { await rm(parent, { recursive: true, force: true }); }
  });
});
