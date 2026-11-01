import { defineConfig, devices } from "@playwright/test";
export default defineConfig({
  testDir: "./tests/event-evening", testMatch: "*.spec.ts", outputDir: "test-results/event-evening",
  fullyParallel: false, retries: 0, reporter: "list",
  use: { baseURL: "http://127.0.0.1:3218", ...devices["Desktop Chrome"] },
  webServer: { command: "node tests/event-evening/server.mjs", url: "http://127.0.0.1:3218", reuseExistingServer: !process.env.CI, timeout: 30_000 },
});
