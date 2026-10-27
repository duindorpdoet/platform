import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { syncSendGridSuppressions } from "./sendgrid-suppressions.mjs";

const hash = (email: string) => createHash("sha256").update(email).digest("hex");
const options = () => ({
  environment: "staging",
  apiKey: "private-provider-fixture",
  rpc: vi.fn().mockResolvedValue(1),
  pause: vi.fn().mockResolvedValue(undefined),
});
const completeCalls = (rpc: ReturnType<typeof vi.fn>) => rpc.mock.calls.filter(([, args]) => args._complete);

describe("automatic SendGrid suppression preservation", () => {
  it("reads every page and list, sends only hashes, and completes after all sources", async () => {
    const settings = options();
    const requests: URL[] = [];
    const fetchImpl = vi.fn(async (url: URL, init: RequestInit) => {
      requests.push(url);
      expect(init.method).toBe("GET");
      expect(init.redirect).toBe("error");
      expect(init.headers).toMatchObject({ Authorization: `Bearer ${settings.apiKey}` });
      expect(url.origin).toBe("https://api.sendgrid.com");
      expect(url.searchParams.get("start_time")).toBe("0");
      const offset = Number(url.searchParams.get("offset"));
      if (offset === 0 && url.pathname.endsWith("/bounces")) return Response.json(Array.from({ length: 500 }, (_, i) => ({ email: `b${i}@example.invalid`, reason: "Private SMTP response" })));
      if (offset === 500) return Response.json([{ email: " Last@Example.Invalid " }]);
      if (offset === 0) return Response.json([{ email: "same@example.invalid" }]);
      return Response.json([]);
    });
    const counts = await syncSendGridSuppressions({ ...settings, fetchImpl });
    expect(counts).toEqual({ unsubscribe: 1, invalid: 1, bounce: 501, spamreport: 1 });
    expect(requests.filter(url => url.pathname.endsWith("/bounces")).map(url => url.searchParams.get("offset"))).toEqual(["0", "500", "501"]);
    expect(new Set(requests.map(url => url.searchParams.get("end_time"))).size).toBe(1);
    expect(settings.rpc).toHaveBeenCalledWith("worker_import_mail_suppressions", expect.objectContaining({
      _environment: "staging", _entries: [{ emailHash: hash("last@example.invalid"), reason: "bounce" }], _complete: false,
    }));
    expect(completeCalls(settings.rpc)).toHaveLength(1);
    expect(settings.rpc.mock.calls.at(-1)?.[1]).toMatchObject({ _entries: [], _complete: true, _source_hash: expect.stringMatching(/^[a-f0-9]{64}$/) });
    const stored = JSON.stringify(settings.rpc.mock.calls);
    expect(stored).not.toContain("@example.invalid");
    expect(stored).not.toContain("Private SMTP response");
    expect(stored).not.toContain(settings.apiKey);
  });

  it("accepts a genuinely empty account only after successful reads of all four sources", async () => {
    const settings = options();
    const fetchImpl = vi.fn(async () => Response.json([]));
    const counts = await syncSendGridSuppressions({ ...settings, fetchImpl });
    expect(fetchImpl).toHaveBeenCalledTimes(4);
    expect(counts).toEqual({ unsubscribe: 0, invalid: 0, bounce: 0, spamreport: 0 });
    expect(settings.rpc).toHaveBeenCalledTimes(1);
    expect(completeCalls(settings.rpc)).toHaveLength(1);
  });

  it.each([401, 403])("does not treat HTTP %s as an empty suppression list", async status => {
    const settings = options();
    const fetchImpl = vi.fn(async () => Response.json({ error: "private@example.invalid" }, { status }));
    await expect(syncSendGridSuppressions({ ...settings, fetchImpl })).rejects.toThrow("SENDGRID_SUPPRESSIONS_READ_ACCESS_REQUIRED");
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(settings.rpc).not.toHaveBeenCalled();
  });

  it("retains partial protective imports without recording completion when the last source fails", async () => {
    const settings = options();
    const fetchImpl = vi.fn(async (url: URL) => {
      if (url.pathname.endsWith("/spam_reports")) return Response.json({ error: "private provider error" }, { status: 503 });
      return Response.json(url.searchParams.get("offset") === "0" ? [{ email: "blocked@example.invalid" }] : []);
    });
    await expect(syncSendGridSuppressions({ ...settings, fetchImpl })).rejects.toThrow("SENDGRID_SUPPRESSIONS_UNAVAILABLE");
    expect(settings.rpc).toHaveBeenCalledTimes(3);
    expect(completeCalls(settings.rpc)).toHaveLength(0);
    expect(settings.pause).toHaveBeenCalledTimes(2);
  });

  it("retries the same read after throttling and bounds Retry-After", async () => {
    const settings = options();
    const fetchImpl = vi.fn()
      .mockResolvedValueOnce(new Response("private", { status: 429, headers: { "retry-after": "3600" } }))
      .mockImplementation(async () => Response.json([]));
    await syncSendGridSuppressions({ ...settings, fetchImpl });
    expect(settings.pause).toHaveBeenCalledWith(5000);
    expect(String(fetchImpl.mock.calls[0][0])).toBe(String(fetchImpl.mock.calls[1][0]));
    expect(completeCalls(settings.rpc)).toHaveLength(1);
  });

  it("bounds network retries and does not expose the original exception", async () => {
    const settings = options();
    const fetchImpl = vi.fn().mockRejectedValue(new Error("private-provider-fixture @ sensitive response"));
    await expect(syncSendGridSuppressions({ ...settings, fetchImpl })).rejects.toThrow(/^SENDGRID_SUPPRESSIONS_UNAVAILABLE$/);
    expect(fetchImpl).toHaveBeenCalledTimes(3);
    expect(settings.rpc).not.toHaveBeenCalled();
  });

  it.each([{}, [null], [{ email: "invalid" }], Array(501).fill({ email: "valid@example.invalid" })])("refuses malformed data instead of silently dropping records", async body => {
    const settings = options();
    await expect(syncSendGridSuppressions({ ...settings, fetchImpl: async () => Response.json(body) })).rejects.toThrow(/SENDGRID_SUPPRESSIONS_INVALID_/);
    expect(settings.rpc).not.toHaveBeenCalled();
  });

  it("bounds actual received bytes without relying on Content-Length", async () => {
    const settings = options();
    await expect(syncSendGridSuppressions({ ...settings, fetchImpl: async () => new Response(" ".repeat(2 * 1024 * 1024 + 1)) })).rejects.toThrow("SENDGRID_SUPPRESSIONS_RESPONSE_TOO_LARGE");
    expect(settings.rpc).not.toHaveBeenCalled();
  });

  it("deduplicates normalized recipients within a page before the database upsert", async () => {
    const settings = options();
    const fetchImpl = async (url: URL) => Response.json(url.searchParams.get("offset") === "0" ? [{ email: "a@example.invalid" }, { email: " A@Example.Invalid " }] : []);
    await syncSendGridSuppressions({ ...settings, fetchImpl });
    expect(settings.rpc.mock.calls[0][1]._entries).toHaveLength(1);
  });

  it("preserves malformed addresses from the invalid-email source", async () => {
    const settings = options();
    const fetchImpl = async (url: URL) => Response.json(url.pathname.endsWith("/invalid_emails") && url.searchParams.get("offset") === "0" ? [{ email: " NOT-AN-ADDRESS " }] : []);
    await syncSendGridSuppressions({ ...settings, fetchImpl });
    expect(settings.rpc).toHaveBeenCalledWith("worker_import_mail_suppressions", expect.objectContaining({
      _entries: [{ emailHash: hash("not-an-address"), reason: "invalid" }], _complete: false,
    }));
    expect(completeCalls(settings.rpc)).toHaveLength(1);
  });

  it("detects a provider ignoring offset instead of looping or marking completion", async () => {
    const settings = options();
    const fetchImpl = vi.fn(async () => Response.json([{ email: "same@example.invalid" }]));
    await expect(syncSendGridSuppressions({ ...settings, fetchImpl })).rejects.toThrow("SENDGRID_SUPPRESSIONS_PAGINATION_REPEATED");
    expect(fetchImpl).toHaveBeenCalledTimes(2);
    expect(completeCalls(settings.rpc)).toHaveLength(0);
  });

  it("stops at the page bound without authorizing an incomplete transfer", async () => {
    const settings = options();
    const fetchImpl = vi.fn(async (url: URL) => Response.json([{ email: `entry${url.searchParams.get("offset")}@example.invalid` }]));
    await expect(syncSendGridSuppressions({ ...settings, fetchImpl })).rejects.toThrow("SENDGRID_SUPPRESSIONS_PAGINATION_LIMIT");
    expect(fetchImpl).toHaveBeenCalledTimes(1000);
    expect(completeCalls(settings.rpc)).toHaveLength(0);
  });

  it("does not continue after a database storage failure", async () => {
    const settings = options();
    settings.rpc.mockRejectedValue(new Error("database unavailable"));
    const fetchImpl = vi.fn(async () => Response.json([{ email: "blocked@example.invalid" }]));
    await expect(syncSendGridSuppressions({ ...settings, fetchImpl })).rejects.toThrow("database unavailable");
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(completeCalls(settings.rpc)).toHaveLength(0);
  });

  it.each(["https://other.invalid/v3", "http://api.sendgrid.com/v3", "https://api.sendgrid.com/v3?forward=1"])("never forwards credentials to %s", async apiBaseUrl => {
    const settings = options();
    const fetchImpl = vi.fn();
    await expect(syncSendGridSuppressions({ ...settings, apiBaseUrl, fetchImpl })).rejects.toThrow("SENDGRID_SUPPRESSIONS_ENDPOINT_INVALID");
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("supports the fixed official EU endpoint", async () => {
    const settings = options();
    const fetchImpl = vi.fn(async (url: URL) => { expect(url.origin).toBe("https://api.eu.sendgrid.com"); return Response.json([]); });
    await syncSendGridSuppressions({ ...settings, apiBaseUrl: "https://api.eu.sendgrid.com/v3", fetchImpl });
    expect(completeCalls(settings.rpc)).toHaveLength(1);
  });

  it("runs the deployment entrypoint without export files, preferring the read credential", () => {
    const code = `globalThis.fetch=async(url,init)=>{
      const u=new URL(String(url));
      if(u.hostname==='api.sendgrid.com') {
        if(init.headers.Authorization!=='Bearer readonly-fixture')throw new Error('Wrong credential');
        return Response.json([]);
      }
      if(u.hostname==='fixture.supabase.co')return Response.json(0);
      throw new Error('Unexpected outbound request');
    };const entry=await import('./scripts/deploy/import-mail-suppressions.mjs');await entry.importMailSuppressions();`;
    const result = spawnSync(process.execPath, ["--input-type=module", "-e", code], { encoding: "utf8", timeout: 5000, env: {
      ...process.env, APP_ENVIRONMENT: "staging", SENDGRID_SUPPRESSIONS_API_KEY: "readonly-fixture", SENDGRID_API: "sending-fixture", SENDGRID_API_BASE_URL: "https://api.sendgrid.com/v3", NEXT_PUBLIC_SUPABASE_URL: "https://fixture.supabase.co", SUPABASE_SERVICE_ROLE_KEY: "local-service-fixture",
    } });
    expect(result.status, result.stderr).toBe(0);
    expect(result.stdout).toContain("automatically imported");
    expect(result.stdout + result.stderr).not.toContain("readonly-fixture");
  });

  it.each(["deploy-staging.yml", "deploy-production.yml"])("automatically imports before provisioning or activation in %s", workflow => {
    const source = readFileSync(`.github/workflows/${workflow}`, "utf8");
    const importer = source.indexOf("node scripts/deploy/import-mail-suppressions.mjs");
    expect(importer).toBeGreaterThan(source.indexOf("node scripts/deploy/bootstrap-mail-config.mjs"));
    expect(importer).toBeLessThan(source.indexOf("node scripts/deploy/configure-resend-webhook.mjs"));
    expect(source).toContain("SENDGRID_SUPPRESSIONS_API_KEY: ${{ secrets.SENDGRID_SUPPRESSIONS_API_KEY }}");
    expect(source.match(/DG_RUNTIME_ENV_KEYS: >-[\s\S]*?steps:/)?.[0]).not.toContain("SENDGRID_SUPPRESSIONS_API_KEY");
    expect(source.match(/supabase secrets set[\s\S]*?supabase functions deploy/)?.[0]).not.toContain("SENDGRID_SUPPRESSIONS_API_KEY");
  });
});
