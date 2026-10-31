import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

// Vite is already a locked dependency of Vitest; do not add or upgrade packages.
const require = createRequire(import.meta.url);
const fromVitest = createRequire(require.resolve("vitest/package.json"));
const { createServer } = await import(pathToFileURL(fromVitest.resolve("vite")).href);
const server = await createServer({ configFile: fileURLToPath(new URL("./vite.config.mts", import.meta.url)) });
await server.listen();
