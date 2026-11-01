import { fileURLToPath } from "node:url";
const here = (path: string) => fileURLToPath(new URL(path, import.meta.url));
const config = { root: here("./"), cacheDir: "/dev/shm/portal-certificate-mail-vite", resolve: { alias: [{ find: "next/link", replacement: here("../poortenboek-refresh/link.tsx") }, { find: "@", replacement: here("../../") }] }, define: { "process.env": {} }, server: { host: "127.0.0.1", port: 3221, strictPort: true, fs: { allow: [here("../../")] } } };
export default config;
