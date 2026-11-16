import { fileURLToPath } from "node:url";
const here = (path: string) => fileURLToPath(new URL(path, import.meta.url));
const config = {
  root: here("./"), cacheDir: "/dev/shm/participant-updates-vite",
  resolve: { alias: [
    { find: "@/lib/supabase/client", replacement: here("./client-fixture.ts") },
    { find: "@", replacement: here("../../") },
  ] },
  define: { "process.env": {} }, css: { postcss: { plugins: [] } },
  server: { host: "127.0.0.1", port: 3220, strictPort: true, fs: { allow: [here("../../")] } },
};
export default config;
