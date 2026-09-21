const [target, expectedUrl] = process.argv.slice(2);
if (!new Set(["staging", "production"]).has(target) || !expectedUrl) {
  throw new Error("Usage: node scripts/deploy/verify-deployment.mjs <staging|production> <url>");
}

const origin = new URL(expectedUrl).origin;
const expectedRegistrationMode = target === "staging" ? "staging_test" : "closed";

async function get(path, init = {}) {
  let lastError;
  for (let attempt = 1; attempt <= 8; attempt += 1) {
    try {
      const response = await fetch(`${origin}${path}`, { redirect: "manual", ...init });
      if (response.status >= 500) throw new Error(`HTTP ${response.status}`);
      return response;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 5_000));
    }
  }
  throw lastError;
}

const healthResponse = await get("/api/health");
if (!healthResponse.ok) throw new Error(`Health check failed with HTTP ${healthResponse.status}.`);
const health = await healthResponse.json();
if (
  health.status !== "ok" ||
  health.service !== "duindorphalloween" ||
  health.environment !== target ||
  health.revision !== process.env.GITHUB_SHA ||
  health.registrationMode !== expectedRegistrationMode
) {
  throw new Error("The health response does not match the deployed release contract.");
}

for (const path of ["/", "/verhaal", "/werelden", "/kaart", "/faq", "/contact", "/sponsoren", "/privacy", "/voorwaarden", "/toegankelijkheid"]) {
  const response = await get(path);
  if (!response.ok) throw new Error(`Public smoke test failed for ${path} (${response.status}).`);
}

for (const path of ["/mijn-inschrijving", "/mijn-huis", "/mijn-groep", "/admin"]) {
  const response = await get(path);
  if (![302, 307, 308].includes(response.status)) throw new Error(`Protected route ${path} did not redirect.`);
  if (!response.headers.get("cache-control")?.includes("no-store")) throw new Error(`Protected route ${path} is cacheable.`);
}

console.log(`${target} deployment ${process.env.GITHUB_SHA} passed its public and protected-route smoke tests.`);
