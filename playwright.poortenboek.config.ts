import { defineConfig, devices } from "@playwright/test";
export default defineConfig({
  testDir: "./tests/e2e",
  testMatch: "poortenboek.spec.ts",
  outputDir: "test-results/poortenboek",
  workers: 1,
  retries: 0,
  timeout: 45_000,
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
    timeout: 45_000,
  },
  projects: [
    {
      name: "book-desktop",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1440, height: 1000 },
      },
    },
    {
      name: "book-samsung-chrome",
      use: { ...devices["Pixel 7"], viewport: { width: 360, height: 800 } },
    },
    {
      name: "book-iphone-webkit",
      use: { ...devices["iPhone 13"], launchOptions: {} },
    },
    {
      name: "book-narrow-reduced-motion",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 320, height: 740 },
        reducedMotion: "reduce",
      },
    },
  ],
});
