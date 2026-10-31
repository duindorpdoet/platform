import { readFile, writeFile, mkdir, readdir, lstat, chmod, rm } from "node:fs/promises";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { join, resolve, isAbsolute } from "node:path";
import { pathToFileURL } from "node:url";

// Official Supabase PostgreSQL17.6.1.167 linux/amd64 image. These public ELF
// bytes and their loader/library closure were independently extracted and hashed.
export const CLIENT_IMAGE = "public.ecr.aws/supabase/postgres@sha256:6942962433a569e87f228b4d4ab7e11db5deca64e43babb3a038443ad6c4f1bb";
export const CLIENT_VERSION = "17.6";
const SOURCE_FILES = [
  {
    "source": "/nix/store/3n3j314vsy174dnwks8dd6c0vrqvh8h6-krb5-1.22.1-lib/lib/libcom_err.so.3",
    "file": "lib/libcom_err.so.3",
    "bytes": 21856,
    "sha256": "63d75b62305bedbca77b98ce40caecb88775f262a5cd091f1bf25f242f7c763f"
  },
  {
    "source": "/nix/store/3n3j314vsy174dnwks8dd6c0vrqvh8h6-krb5-1.22.1-lib/lib/libgssapi_krb5.so.2",
    "file": "lib/libgssapi_krb5.so.2",
    "bytes": 404552,
    "sha256": "74a696bb1aed6612d07fdc5c25a1b42ba7327327df02d83dc5e203b84a2f8aaf"
  },
  {
    "source": "/nix/store/3n3j314vsy174dnwks8dd6c0vrqvh8h6-krb5-1.22.1-lib/lib/libk5crypto.so.3",
    "file": "lib/libk5crypto.so.3",
    "bytes": 205728,
    "sha256": "99da61efe1571f31221d98e2aa2bb6b77a9064683fb60da8deaa381068b1c2e7"
  },
  {
    "source": "/nix/store/3n3j314vsy174dnwks8dd6c0vrqvh8h6-krb5-1.22.1-lib/lib/libkrb5.so.3",
    "file": "lib/libkrb5.so.3",
    "bytes": 1066968,
    "sha256": "fa484cd0e332012553935d0798bebb96136824896c7d563181071aa4c44d353e"
  },
  {
    "source": "/nix/store/3n3j314vsy174dnwks8dd6c0vrqvh8h6-krb5-1.22.1-lib/lib/libkrb5support.so.0",
    "file": "lib/libkrb5support.so.0",
    "bytes": 65688,
    "sha256": "403f42d60d0713e2c011b35f4a39cf1e3bc5a7bb7cbf3a539d1f3b1bbda04ad3"
  },
  {
    "source": "/nix/store/bk5b5k07j29a1cwglzl6zaissg0bi8i1-keyutils-1.6.3-lib/lib/libkeyutils.so.1",
    "file": "lib/libkeyutils.so.1",
    "bytes": 26616,
    "sha256": "e8ad9b59e7d805181c26f4a41ce6225034a4c90ace7c58d4d4a199dcfca90d8e"
  },
  {
    "source": "/nix/store/c2qsgf2832zi4n29gfkqgkjpvmbmxam6-zlib-1.3.1/lib/libz.so.1",
    "file": "lib/libz.so.1",
    "bytes": 128576,
    "sha256": "9dafd654792106dc7b496ef621b1f64e27ab9925793301355b235884756bb715"
  },
  {
    "source": "/nix/store/d43fya852vmrp5hws2lrw47ccq1ngakz-postgresql-17.6/bin/pg_dump",
    "file": "elf/pg_dump",
    "bytes": 520456,
    "sha256": "858f1d46d266b6d3aa514e8483cd4d8ca43ac792b72451b448fcd00903b48eb4"
  },
  {
    "source": "/nix/store/d43fya852vmrp5hws2lrw47ccq1ngakz-postgresql-17.6/bin/pg_restore",
    "file": "elf/pg_restore",
    "bytes": 282504,
    "sha256": "34e80db8f1f644692e430bd8785fa17ae2b7072177da02d25b31d35d60b49339"
  },
  {
    "source": "/nix/store/d43fya852vmrp5hws2lrw47ccq1ngakz-postgresql-17.6/bin/psql",
    "file": "elf/psql",
    "bytes": 838960,
    "sha256": "96577e53f4c3558b7f27c5747b533bc7180a4b22a232e8a71af7724257d7efcc"
  },
  {
    "source": "/nix/store/ddranxbikfg4jkf3n1m0a0h9qqxj1vf0-ncurses-6.5/lib/libncursesw.so.6",
    "file": "lib/libncursesw.so.6",
    "bytes": 542656,
    "sha256": "be8af6c64a4cfcce88a4ac09cd0afc1f601fd41364aea8c109cb7758be5679cf"
  },
  {
    "source": "/nix/store/dv5vqr2v73jr9bfrgvb1bsblzzl1nl4y-lz4-1.10.0-lib/lib/liblz4.so.1",
    "file": "lib/liblz4.so.1",
    "bytes": 261256,
    "sha256": "1898b768dd793c584d6c80b5ed775487164c81f9e3b262d4976433df6623fa2e"
  },
  {
    "source": "/nix/store/hxirsdsijn15fz7bji9l1jb47x4dhbq4-postgresql-17.6-lib/lib/libpq.so.5",
    "file": "lib/libpq.so.5",
    "bytes": 398064,
    "sha256": "0eaed5c0011c0c41925bec2796df3b2a85c5855087331769352302de1b6f0b3f"
  },
  {
    "source": "/nix/store/j193mfi0f921y0kfs8vjc1znnr45ispv-glibc-2.40-66/lib/ld-linux-x86-64.so.2",
    "file": "lib/ld-linux-x86-64.so.2",
    "bytes": 253696,
    "sha256": "1e08370bba3ee9e4f97bb0500d1f32afb0417babca6ae455c6458b9a3edb86a8"
  },
  {
    "source": "/nix/store/j193mfi0f921y0kfs8vjc1znnr45ispv-glibc-2.40-66/lib/libc.so.6",
    "file": "lib/libc.so.6",
    "bytes": 2413048,
    "sha256": "29ed835214dc8bc811e10f384ac5428148418bdc7d93f43e5f3a6880bd6dc903"
  },
  {
    "source": "/nix/store/j193mfi0f921y0kfs8vjc1znnr45ispv-glibc-2.40-66/lib/libdl.so.2",
    "file": "lib/libdl.so.2",
    "bytes": 15688,
    "sha256": "0b410a4dc1e19583f1bbd192ff5d09de4208715a04d6d11c28fdbda01e1c6bb0"
  },
  {
    "source": "/nix/store/j193mfi0f921y0kfs8vjc1znnr45ispv-glibc-2.40-66/lib/libm.so.6",
    "file": "lib/libm.so.6",
    "bytes": 1029504,
    "sha256": "2e1c8e9e8d5fbefde85eb1d0750375da636ea65aa918b7fdcc328f07f3e6c01e"
  },
  {
    "source": "/nix/store/j193mfi0f921y0kfs8vjc1znnr45ispv-glibc-2.40-66/lib/libpthread.so.0",
    "file": "lib/libpthread.so.0",
    "bytes": 16536,
    "sha256": "a4150ff6ddfe86384f38fc78d181fb1c0c77b413a172d4fff10176b4084dec43"
  },
  {
    "source": "/nix/store/j193mfi0f921y0kfs8vjc1znnr45ispv-glibc-2.40-66/lib/libresolv.so.2",
    "file": "lib/libresolv.so.2",
    "bytes": 77152,
    "sha256": "2a52e8de1bd98665a08f66bba19269949003a4b020338836129afd023047dc59"
  },
  {
    "source": "/nix/store/rfm5m2l26lqkskcvxn5bm5xqh6c8wqr5-openssl-3.6.0/lib/libcrypto.so.3",
    "file": "lib/libcrypto.so.3",
    "bytes": 7606376,
    "sha256": "9c298d15748740096a2cc79d9fae4edd66c368a9c054c4eeeeb823160b71c0fc"
  },
  {
    "source": "/nix/store/rfm5m2l26lqkskcvxn5bm5xqh6c8wqr5-openssl-3.6.0/lib/libssl.so.3",
    "file": "lib/libssl.so.3",
    "bytes": 1324464,
    "sha256": "27b3b1454ba2d358dc4a74ab3cbbba81b045ede81e215c3dac92e45d89bfff2a"
  },
  {
    "source": "/nix/store/vksayvpb9qm9h32k0qqg67nclrq8sf79-readline-8.3p1/lib/libreadline.so.8",
    "file": "lib/libreadline.so.8",
    "bytes": 441776,
    "sha256": "1ef7621ebcf3c9a6a917cf9641652eac1d76faf7f7de7a55d6d728924d1d1eda"
  },
  {
    "source": "/nix/store/w07dqm9na06xgf9vbs0xqrlzya9p7g6b-zstd-1.5.7/lib/libzstd.so.1",
    "file": "lib/libzstd.so.1",
    "bytes": 905672,
    "sha256": "c6072447026f9776b229e4978d708629fb963e9bfe64d64406ac2061ba5b54ec"
  }
];
const tools = ["psql", "pg_dump", "pg_restore"];
const hash = data => createHash("sha256").update(data).digest("hex");
const fail = code => { throw new Error(`PORTABLE_PG_${code}`); };
function wrapper(name) {
  return `#!/bin/sh\nset -eu\ntask_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)\nexec "$task_root/lib/ld-linux-x86-64.so.2" --library-path "$task_root/lib" "$task_root/elf/${name}" "$@"\n`;
}
export function portableClientManifest() {
  return { version: 1, clientVersion: CLIENT_VERSION, platform: "linux-amd64", sourceImage: CLIENT_IMAGE,
    files: [...SOURCE_FILES.map(({ file, bytes, sha256 }) => ({ file, bytes, sha256 })),
      ...tools.map(name => ({ file: `bin/${name}`, bytes: Buffer.byteLength(wrapper(name)), sha256: hash(wrapper(name)) }))].sort((a, b) => a.file.localeCompare(b.file)) };
}
const manifestText = () => JSON.stringify(portableClientManifest(), null, 2) + "\n";
function directoryPath(directory) {
  if (typeof directory !== "string" || !isAbsolute(directory) || directory.includes("\0") || resolve(directory) === "/") fail("DIRECTORY_REQUIRED");
  return resolve(directory);
}
async function inspectOwned(path, directory) {
  const stat = await lstat(path);
  if (stat.isSymbolicLink() || (directory ? !stat.isDirectory() : !stat.isFile() || stat.nlink !== 1)
    || stat.uid !== process.getuid() || (stat.mode & 0o022) !== 0) fail("UNSAFE_FILESYSTEM");
  return stat;
}

/** Validate every pinned byte before enabling execution in the user directory. */
export async function validatePortablePostgresClient(directory) {
  directory = directoryPath(directory);
  try {
    await inspectOwned(directory, true);
    const manifest = portableClientManifest(), expected = new Map(manifest.files.map(row => [row.file, row]));
    const text = manifestText(), manifestInfo = await inspectOwned(join(directory, "manifest.json"), false);
    if (manifestInfo.size !== Buffer.byteLength(text) || (await readFile(join(directory, "manifest.json"), "utf8")) !== text) fail("MANIFEST_MISMATCH");
    const allowedRoots = ["bin", "elf", "lib", "manifest.json"];
    const roots = await readdir(directory);
    if (roots.length !== allowedRoots.length || roots.some(value => !allowedRoots.includes(value))) fail("UNEXPECTED_FILES");
    const seen = new Set();
    for (const subdir of ["bin", "elf", "lib"]) {
      await inspectOwned(join(directory, subdir), true);
      for (const name of await readdir(join(directory, subdir))) {
        const file = `${subdir}/${name}`, row = expected.get(file);
        if (!row) fail("UNEXPECTED_FILES");
        const info = await inspectOwned(join(directory, file), false);
        if (info.size !== row.bytes || hash(await readFile(join(directory, file))) !== row.sha256) fail("FILE_INTEGRITY");
        seen.add(file);
      }
    }
    if (seen.size !== expected.size) fail("INCOMPLETE_FILES");
    // Artifact download preserves bytes but removes executable permissions.
    // Activate only after the whole fixed manifest has been independently checked.
    for (const file of expected.keys()) await chmod(join(directory, file), 0o700);
    for (const subdir of ["bin", "elf", "lib"]) await chmod(join(directory, subdir), 0o700);
    await chmod(directory, 0o700); await chmod(join(directory, "manifest.json"), 0o600);
    return { directory, binDir: join(directory, "bin"), psql: join(directory, "bin/psql"), pgDump: join(directory, "bin/pg_dump"),
      pgRestore: join(directory, "bin/pg_restore"), manifestSha256: hash(text), version: CLIENT_VERSION, sourceImage: CLIENT_IMAGE };
  } catch (error) {
    if (/^PORTABLE_PG_[A-Z0-9_]+$/.test(error?.message ?? "")) throw error;
    fail("VALIDATION_FAILED");
  }
}

function command(args) {
  return new Promise((resolve, reject) => {
    execFile("docker", args, { timeout: args[0] === "pull" ? 180000 : 30000, killSignal: "SIGKILL", maxBuffer: 4096 },
      (error, stdout) => error ? reject(new Error("PORTABLE_PG_DOCKER_FAILED")) : resolve(stdout.trim()));
  });
}

/** Public artifacts only. Docker is needed on this producer, never the VPS. */
export async function buildPortablePostgresClient(directory, execute = command) {
  directory = directoryPath(directory);
  if (process.platform !== "linux" || process.arch !== "x64") fail("PLATFORM_REQUIRED");
  let created = false, container;
  try {
    await mkdir(directory, { mode: 0o700 }); created = true;
    for (const subdir of ["bin", "elf", "lib"]) await mkdir(join(directory, subdir), { mode: 0o700 });
    await execute(["pull", "--platform", "linux/amd64", CLIENT_IMAGE]);
    container = await execute(["create", "--platform", "linux/amd64", "--network", "none", "--entrypoint", "sh", CLIENT_IMAGE, "-c", "exit 0"]);
    if (typeof container !== "string" || !/^[a-f0-9]{64}$/.test(container)) fail("CONTAINER_ID_REQUIRED");
    for (const row of SOURCE_FILES) await execute(["cp", "-L", `${container}:${row.source}`, join(directory, row.file)]);
    for (const name of tools) await writeFile(join(directory, "bin", name), wrapper(name), { flag: "wx", mode: 0o600 });
    await writeFile(join(directory, "manifest.json"), manifestText(), { flag: "wx", mode: 0o600 });
    return await validatePortablePostgresClient(directory);
  } catch (error) {
    if (created) await rm(directory, { recursive: true, force: true });
    if (/^PORTABLE_PG_[A-Z0-9_]+$/.test(error?.message ?? "")) throw error;
    fail("BUILD_FAILED");
  } finally {
    if (typeof container === "string" && /^[a-f0-9]{64}$/.test(container)) {
      try { await execute(["rm", "--force", container]); } catch { fail("CONTAINER_CLEANUP_FAILED"); }
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [mode, directory] = process.argv.slice(2);
  try {
    if (!["build", "verify"].includes(mode)) fail("MODE_REQUIRED");
    const result = await (mode === "build" ? buildPortablePostgresClient(directory) : validatePortablePostgresClient(directory));
    console.log(JSON.stringify({ clientVersion: result.version, sourceImage: result.sourceImage, manifestSha256: result.manifestSha256, files: portableClientManifest().files.length }));
  } catch (error) { console.error(/^PORTABLE_PG_[A-Z0-9_]+$/.test(error?.message ?? "") ? error.message : "PORTABLE_PG_FAILED"); process.exitCode = 1; }
}
