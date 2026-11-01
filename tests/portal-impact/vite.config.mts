import { fileURLToPath } from "node:url";
const here = (path: string) => fileURLToPath(new URL(path, import.meta.url));
const config = { root: here("./"), publicDir: here("../../public"), cacheDir: "/dev/shm/portal-impact-vite", resolve: { alias: [{ find: "@", replacement: here("../../") }] }, define: { "process.env": {} }, server: { host: "127.0.0.1", port: 3220, strictPort: true, fs: { allow: [here("../../")] } } };
export default config;
