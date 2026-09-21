import { expect, test } from "@playwright/test";

test("protected pages and APIs are never publicly cached", async ({ request }) => {
  const protectedResponse = await request.get("/mijn-inschrijving", { maxRedirects: 0 });
  expect(protectedResponse.headers()["cache-control"]).toContain("private");
  expect(protectedResponse.headers()["x-robots-tag"]).toContain("noindex");
  const apiResponse = await request.post("/api/jobs/mail");
  expect(apiResponse.headers()["cache-control"]).toContain("private");
});

test("baseline browser security headers are present", async ({ request }) => {
  const response = await request.get("/");
  expect(response.headers()["x-content-type-options"]).toBe("nosniff");
  expect(response.headers()["x-frame-options"]).toBe("DENY");
  expect(response.headers()["referrer-policy"]).toBe("strict-origin-when-cross-origin");
  expect(response.headers()["permissions-policy"]).toContain("camera=(self)");
});

test("deployment health contract exposes no secrets", async ({ request }) => {
  const response = await request.get("/api/health");
  expect(response.ok()).toBeTruthy();
  const health = await response.json();
  expect(health).toMatchObject({ status: "ok", service: "duindorphalloween", registrationMode: "closed" });
  expect(JSON.stringify(health)).not.toMatch(/key|secret|token/i);
});
