import { defineConfig, devices } from "@playwright/test";
export default defineConfig({
  testDir: "./tests/participant-updates", testMatch: "*.spec.ts", fullyParallel: false, retries: 0,
  outputDir: process.env.PARTICIPANT_UPDATES_TEST_OUTPUT ?? "test-results/participant-updates", reporter: "list",
  use: { baseURL: "http://127.0.0.1:3220", ...devices["Desktop Chrome"], ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH ? { launchOptions: { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH } } : {}) },
  webServer: { command: "node tests/participant-updates/server.mjs", url: "http://127.0.0.1:3220", reuseExistingServer: !process.env.CI, timeout: 30_000 },
});
