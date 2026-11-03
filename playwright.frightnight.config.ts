import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "./tests/e2e",
  testMatch: "frightnight.spec.ts",
  outputDir: "test-results/frightnight",
  fullyParallel: false,
  workers: 1,
  timeout: 60_000,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["html", { outputFolder: "playwright-report/frightnight", open: "never" }], ["github"]] : "list",
  use: { baseURL: "http://127.0.0.1:3137", viewport: { width: 1440, height: 1000 }, reducedMotion: "reduce", serviceWorkers: "block", trace: "retain-on-failure", screenshot: "only-on-failure" },
  webServer: {
    command: "pnpm start --port 3137",
    url: "http://127.0.0.1:3137",
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
    env: { FRIGHTNIGHT_ENABLED: "true", APP_ENVIRONMENT: "test", EVENT_SLUG: "frightnight-2027-test", APP_URL: "http://127.0.0.1:3137", ALLOWED_ORIGINS: "http://127.0.0.1:3137", RAYON_NUM_THREADS: "2", NEXT_TELEMETRY_DISABLED: "1" },
  },
});
