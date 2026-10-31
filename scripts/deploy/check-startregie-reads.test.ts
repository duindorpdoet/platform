import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { ACTOR_QUERY, checkStartregieReads } from "./check-startregie-reads.mjs";

const actor = "11111111-1111-4111-8111-111111111111";
const draft = "22222222-2222-4222-8222-222222222222";
const published = "33333333-3333-4333-8333-333333333333";
const signingSecret = "private-test-only-jwt-signing-secret";
const privateMessage = "PRIVATE_ADDRESS_OR_PROVIDER_SECRET";
const env = {
  APP_ENVIRONMENT: "production", SUPABASE_PROJECT_REF: "dtubngvxfbupgvgfrjko",
  NEXT_PUBLIC_SUPABASE_URL: "https://dtubngvxfbupgvgfrjko.supabase.co",
  NEXT_PUBLIC_SUPABASE_ANON_KEY: "public-test-key", SUPABASE_ACCESS_TOKEN: "private-management-token",
  APP_REVISION: "a".repeat(40), GITHUB_SHA: "a".repeat(40),
  GITHUB_REPOSITORY: "duindorpdoet/platform", GITHUB_REF: "refs/heads/production",
};
const snapshot = (revision = 1) => ({
  settings: { eventSettingsVersion: 103 }, privateAddress: privateMessage,
  ops: { groups: [
    { scheduleId: draft, revision, state: "draft" },
    { scheduleId: published, revision: 8, state: "published", timePublishedAt: "2026-10-30" },
    { scheduleId: null, revision: 0, state: "unassigned" },
  ] },
});

function fixture(options: { empty?: boolean; failure?: "snapshot" | "readiness"; invalidJson?: boolean; fetchError?: boolean; missingActor?: boolean } = {}) {
  let reads = 0;
  const request = vi.fn<typeof fetch>(async (input, init) => {
    const url = String(input);
    if (options.fetchError) throw new Error(privateMessage);
    if (url.endsWith("/database/query")) return Response.json(options.missingActor ? [] : [{ actor_id: actor, functions_stable: true }]);
    if (url.endsWith("/postgrest")) return Response.json({ jwt_secret: signingSecret });
    if (url.endsWith("/rpc/admin_startregie_snapshot")) {
      if (options.failure === "snapshot") return Response.json({ message: privateMessage }, { status: 500 });
      if (options.invalidJson) return new Response(privateMessage);
      reads++;
      return Response.json(options.empty ? { settings: { eventSettingsVersion: 103 }, ops: { groups: [] } } : snapshot(reads));
    }
    if (url.endsWith("/rpc/admin_startregie_publication_readiness")) {
      if (options.failure === "readiness") return Response.json({ message: privateMessage }, { status: 503 });
      expect(JSON.parse(String(init?.body))).toEqual({
        _event_slug: "duindorp-halloween-2026", _expected_settings_version: 103,
        _expected_revisions: [{ id: draft, revision: reads }, { id: published, revision: 8 }],
      });
      return Response.json({ ready: false, reasons: [{ code: "FINALE_CAPACITY_EXCEEDED", message: privateMessage }] });
    }
    throw new Error(`Unexpected endpoint ${url}`);
  });
  let time = 0;
  return { request, clock: () => time += 5 };
}

describe("production Startregie HTTP read acceptance", () => {
  it("reads every current schedule, including published revisions, freshly three times without write endpoints", async () => {
    const { request, clock } = fixture();
    const timeout = vi.spyOn(AbortSignal, "timeout");
    try {
      const result = await checkStartregieReads(env, request, clock);
      expect(result).toMatchObject({ readOnly: true, changedRows: 0, messagesSent: 0, productionPerformanceProven: true });
      expect(result.checks).toHaveLength(3);
      expect(result.checks.every(check => check.currentSchedules === 2 && check.ready === false && check.readinessMs === 5)).toBe(true);
      expect(result.checks[0].reasonCodes).toEqual(["FINALE_CAPACITY_EXCEEDED"]);
      expect(request).toHaveBeenCalledTimes(8);
      expect(timeout.mock.calls.every(([milliseconds]) => milliseconds === 20_000)).toBe(true);
      const [firstUrl, first] = request.mock.calls[0];
      expect(String(firstUrl)).toBe("https://api.supabase.com/v1/projects/dtubngvxfbupgvgfrjko/database/query");
      expect(JSON.parse(String(first?.body))).toEqual({ read_only: true, query: ACTOR_QUERY });
      expect(ACTOR_QUERY).toContain("capability.revoked_at is null");
      expect(ACTOR_QUERY).toContain("account.email_confirmed_at is not null");
      expect(ACTOR_QUERY).toContain("account.banned_until<=statement_timestamp()");
      expect(request.mock.calls[1][1]?.method).toBe("GET");
      for (const [url, init] of request.mock.calls.slice(2)) {
        expect(String(url)).toMatch(/\/rpc\/admin_startregie_(snapshot|publication_readiness)$/);
        expect(init?.method).toBe("POST");
        const headers = new Headers(init?.headers);
        expect(headers.get("content-profile")).toBe("api");
        expect(headers.get("apikey")).toBe("public-test-key");
        const token = headers.get("authorization")!.slice("Bearer ".length);
        const [header, payload, signature] = token.split(".");
        const claims = JSON.parse(Buffer.from(payload, "base64url").toString());
        expect(claims).toMatchObject({ sub: actor, role: "authenticated", aud: "authenticated" });
        expect(claims.exp - claims.iat).toBeLessThanOrEqual(120);
        expect(signature).toBe(createHmac("sha256", signingSecret).update(`${header}.${payload}`).digest("base64url"));
      }
      const printed = JSON.stringify(result);
      for (const value of [actor, draft, published, signingSecret, privateMessage, env.SUPABASE_ACCESS_TOKEN]) expect(printed).not.toContain(value);
    } finally { timeout.mockRestore(); }
  });

  it("requires real production groups and schedules", async () => {
    const { request, clock } = fixture({ empty: true });
    await expect(checkStartregieReads(env, request, clock)).rejects.toThrow("STARTREGIE_READ_CHECK_REAL_PRODUCTION_GROUPS_REQUIRED");
    expect(request).toHaveBeenCalledTimes(3);
  });

  it("states that empty staging has no production performance proof and never sends a fake readiness selection", async () => {
    const { request, clock } = fixture({ empty: true });
    const result = await checkStartregieReads({ ...env, APP_ENVIRONMENT: "staging", GITHUB_REF: "refs/heads/staging", SUPABASE_PROJECT_REF: "nocteiuvohesvqbowchw", NEXT_PUBLIC_SUPABASE_URL: "https://nocteiuvohesvqbowchw.supabase.co" }, request, clock);
    expect(result.productionPerformanceProven).toBe(false);
    expect(result.checks.every(check => check.readinessSkipped?.includes("does not prove production performance"))).toBe(true);
    expect(request.mock.calls.filter(([url]) => String(url).includes("publication_readiness"))).toHaveLength(0);
  });

  it.each(["snapshot", "readiness"] as const)("fails closed on an unsuccessful %s read without printing returned private details", async failure => {
    const { request, clock } = fixture({ failure });
    await expect(checkStartregieReads(env, request, clock)).rejects.toThrow(failure === "snapshot" ? "STARTREGIE_READ_CHECK_SNAPSHOT_HTTP_500" : "STARTREGIE_READ_CHECK_READINESS_HTTP_503");
    expect(request.mock.calls.filter(([url]) => String(url).endsWith("/rpc/admin_startregie_snapshot"))).toHaveLength(1);
    expect(request.mock.calls.filter(([url]) => String(url).endsWith("/rpc/admin_startregie_publication_readiness"))).toHaveLength(failure === "readiness" ? 1 : 0);
  });

  it("redacts network errors and invalid JSON responses", async () => {
    for (const options of [{ fetchError: true }, { invalidJson: true }]) {
      const { request, clock } = fixture(options);
      const error = await checkStartregieReads(env, request, clock).then(() => null, error => error as Error);
      expect(error).toBeInstanceOf(Error);
      expect(error?.message).not.toContain(privateMessage);
      expect(error?.message).toMatch(/^STARTREGIE_READ_CHECK_[A-Z0-9_]+$/);
    }
  });

  it("rejects a response at the ten-second boundary despite the twenty-second client deadline", async () => {
    const { request } = fixture();
    let time = 0;
    await expect(checkStartregieReads(env, request, () => time += 10_000)).rejects.toThrow("STARTREGIE_READ_CHECK_TEN_SECOND_MARGIN_EXCEEDED");
  });

  it("never creates an account or token session when no existing authorized actor is present", async () => {
    const { request, clock } = fixture({ missingActor: true });
    await expect(checkStartregieReads(env, request, clock)).rejects.toThrow("STARTREGIE_READ_CHECK_EXISTING_AUTHORIZED_ADMIN_REQUIRED");
    expect(request).toHaveBeenCalledTimes(1);
  });

  it("refuses to call HTTP functions whose stable read contract has changed", async () => {
    const request = vi.fn<typeof fetch>(async () => Response.json([{ actor_id: actor, functions_stable: false }]));
    await expect(checkStartregieReads(env, request)).rejects.toThrow("STARTREGIE_READ_CHECK_STABLE_READ_FUNCTIONS_REQUIRED");
    expect(request).toHaveBeenCalledTimes(1);
  });

  it.each([
    { SUPABASE_PROJECT_REF: "nocteiuvohesvqbowchw", NEXT_PUBLIC_SUPABASE_URL: "https://nocteiuvohesvqbowchw.supabase.co" },
    { NEXT_PUBLIC_SUPABASE_URL: "https://example.invalid" },
    { GITHUB_SHA: "b".repeat(40) },
    { GITHUB_REF: "refs/heads/main" },
  ])("rejects crossed environments and unverified revisions before any request: %j", async change => {
    const { request, clock } = fixture();
    await expect(checkStartregieReads({ ...env, ...change }, request, clock)).rejects.toThrow("STARTREGIE_READ_CHECK_RELEASE_CONFIGURATION");
    expect(request).not.toHaveBeenCalled();
  });

  it.each(["production", "staging"])("runs after exact application revision verification on %s", environment => {
    const source = readFileSync(`.github/workflows/deploy-${environment}.yml`, "utf8");
    const revisionCheck = source.indexOf(`run: node scripts/deploy/verify-deployment.mjs ${environment}`);
    expect(revisionCheck).toBeGreaterThan(0);
    expect(source.indexOf("run: node scripts/deploy/check-startregie-reads.mjs")).toBeGreaterThan(revisionCheck);
  });
});
