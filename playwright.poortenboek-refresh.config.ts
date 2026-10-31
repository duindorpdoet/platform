import { defineConfig, devices } from "@playwright/test";

// Browser-only integration of the real book/guide, with a controlled transport.
// This server has no database credentials and binds only to localhost.
export default defineConfig({
  testDir: "./tests/poortenboek-refresh",
  testMatch: "*.spec.ts",
  outputDir: "test-results/poortenboek-refresh",
  fullyParallel: false,
  retries: 0,
  reporter: "list",
  use: { baseURL: "http://127.0.0.1:3217", ...devices["Desktop Chrome"] },
  webServer: {
    command: "node tests/poortenboek-refresh/server.mjs",
    url: "http://127.0.0.1:3217",
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },
});
