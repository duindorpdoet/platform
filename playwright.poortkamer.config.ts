import { defineConfig, devices } from "@playwright/test";
export default defineConfig({
  testDir: "./tests/e2e",
  testMatch: "poortkamer.spec.ts",
  outputDir: "test-results/poortkamer",
  workers: 1,
  retries: 0,
  timeout: 90_000,
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
    url: "https://127.0.0.1:3443/poortenboek/inloggen",
    ignoreHTTPSErrors: true,
    timeout: 60_000,
  },
  projects: [
    {
      name: "room-desktop",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1440, height: 1000 },
      },
    },
    {
      name: "room-samsung-chrome",
      use: { ...devices["Pixel 7"], viewport: { width: 360, height: 800 } },
    },
    {
      name: "room-iphone-webkit",
      use: { ...devices["iPhone 13"], launchOptions: {} },
    },
    {
      name: "room-tablet",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 820, height: 1180 },
      },
    },
    {
      name: "room-narrow-reduced-motion",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 320, height: 740 },
        reducedMotion: "reduce",
      },
    },
  ],
});
