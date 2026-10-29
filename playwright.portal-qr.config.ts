import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/e2e", testMatch: "portal-qr-persistence.spec.ts", outputDir: "test-results/portal-qr",
  workers: 1, retries: 0, timeout: 180_000, reporter: "list",
  use: { serviceWorkers: "block", baseURL: "https://127.0.0.1:3443", ignoreHTTPSErrors: true, launchOptions: { args: ["--ignore-certificate-errors"] }, trace: "retain-on-failure", screenshot: "only-on-failure" },
  webServer: { command: "node scripts/acceptance/poortenboek-server.mjs", url: "https://127.0.0.1:3443/poortenboek/inloggen", ignoreHTTPSErrors: true, timeout: 45_000 },
  projects: [
    { name: "qr-desktop", use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 1000 } } },
    { name: "qr-mobile", use: { ...devices["Pixel 7"], viewport: { width: 360, height: 800 } } },
  ],
});
