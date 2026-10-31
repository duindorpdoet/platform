import { fileURLToPath } from "node:url";

const here = (path: string) => fileURLToPath(new URL(path, import.meta.url));
const config = {
  root: here("./"),
  cacheDir: "/tmp/poortenboek-refresh-vite",
  resolve: { alias: {
    "@": here("../../"),
    "next/navigation": here("./navigation.tsx"),
    "next/link": here("./link.tsx"),
  } },
  define: { "process.env": {} },
  server: { host: "127.0.0.1", port: 3217, strictPort: true, fs: { allow: [here("../../")] } },
};
export default config;
