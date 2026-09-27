import { defineConfig, devices } from "@playwright/test";
export default defineConfig({
  testDir: "./tests/e2e",
  testMatch: "redactiekamer.spec.ts",
  outputDir: "test-results/editorial",
  workers: 1,
  retries: 0,
  timeout: 90000,
  reporter: "list",
  use: {
    baseURL: "https://127.0.0.1:3443",
    ignoreHTTPSErrors: true,
    launchOptions: { args: ["--ignore-certificate-errors"] },
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  webServer: {
    command: "node scripts/acceptance/poortenboek-server.mjs",
    url: "https://127.0.0.1:3443",
    ignoreHTTPSErrors: true,
    reuseExistingServer: true,
    timeout: 45000,
  },
  projects: [
    {
      name: "editorial-desktop",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1440, height: 1000 },
      },
    },
    {
      name: "editorial-samsung-chrome",
      use: { ...devices["Pixel 7"], viewport: { width: 360, height: 800 } },
    },
    {
      name: "editorial-iphone-webkit",
      use: { ...devices["iPhone 13"], launchOptions: {} },
    },
    {
      name: "editorial-narrow",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 320, height: 740 },
        reducedMotion: "reduce",
      },
    },
  ],
});
