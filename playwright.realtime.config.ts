import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/e2e",
  testMatch: "realtime-pressure.spec.ts",
  outputDir: "test-results/realtime",
  workers: 1,
  retries: 0,
  timeout: 60_000,
  reporter: "list",
  use: { baseURL: "http://127.0.0.1:3187", trace: "retain-on-failure", screenshot: "only-on-failure" },
  webServer: { command: "pnpm start --port 3187", url: "http://127.0.0.1:3187/inloggen", reuseExistingServer: false, timeout: 30_000 },
  projects: [{ name: "realtime-chromium", use: { ...devices["Desktop Chrome"] } }],
});
