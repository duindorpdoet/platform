import { defineConfig, devices } from "@playwright/test";
import room from "./playwright.poortkamer.config";

// A required real Auth/HTTP/database gate. The acceptance filename is deliberately
// outside the ordinary unit/browser matches; missing local credentials fail here.
export default defineConfig({
  ...room,
  testMatch: "poortkamer-thanks-closed.acceptance.ts",
  outputDir: "test-results/poortkamer-thanks-closed",
  timeout: 180_000,
  use: { ...room.use, serviceWorkers: "block" },
  projects: [{
    name: "thanks-closed-real-http",
    use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 1000 } },
  }],
});
