import { fileURLToPath } from "node:url";
const here = (path: string) => fileURLToPath(new URL(path, import.meta.url));
const config = {
  root: here("./"), cacheDir: "/dev/shm/event-evening-vite",
  resolve: { alias: [
    { find: "@/components/redesign/portal-thanks", replacement: here("./thanks.tsx") },
    { find: "next/link", replacement: here("../poortenboek-refresh/link.tsx") },
    { find: "@", replacement: here("../../") },
  ] },
  define: { "process.env": {} },
  server: { host: "127.0.0.1", port: 3218, strictPort: true, fs: { allow: [here("../../")] } },
};

export default config;
