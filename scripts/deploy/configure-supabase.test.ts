import { spawnSync } from "node:child_process";
import { describe, expect, it } from "vitest";

function configure(probeResult: object, runtimeStatus = 200, environment: Record<string, string> = {}) {
  const code = `
    const runtimeStatus = ${runtimeStatus};
    globalThis.fetch = async (input, init = {}) => {
      const url = new URL(String(input));
      let body = {};

      if (url.origin === 'https://staging.example.invalid' && url.pathname === '/api/jobs/mail') {
        return new Response(
          runtimeStatus === 200 ? JSON.stringify({ probe: 'transactional_gateway', accepted: true }) : 'runtime probe failed',
          { status: runtimeStatus, headers: { 'content-type': 'application/json' } },
        );
      }

      if (url.pathname.endsWith('/config/auth') && init.method !== 'PATCH') {
        body = {
          mailer_autoconfirm: false,
          mailer_allow_unverified_email_sign_ins: false,
          mailer_secure_email_change_enabled: true,
          mailer_otp_exp: 600,
          mailer_otp_length: 6,
          hook_send_email_enabled: true,
          hook_send_email_uri: 'https://project-ref.supabase.co/functions/v1/send-email-hook',
          rate_limit_email_sent: 30,
        };
      }

      if (url.pathname.endsWith('/configure_release_mode')) {
        const requested = JSON.parse(init.body)._mode;
        if (process.env.REGISTRATION_MODE === 'live' && requested !== 'production_open') throw new Error('Live deployment did not request participant opening');
        body = {
          releaseMode: requested,
          phase: 'registration_open',
          registrationPublished: true,
          groupRegistrationOpen: true,
          portalRegistrationOpen: true,
        };
      }

      if (url.pathname.endsWith('/configure_notification_recipient')) {
        const payload = JSON.parse(init.body);
        if (payload._email !== 'test@example.nl' || payload._event_slug !== 'event') {
          throw new Error('Incorrect fixed notification recipient');
        }
        console.log('Fixed staging notification recipient configured.');
      }

      if (url.pathname.endsWith('/configure_mail_worker')) {
        body = {
          active: true,
        };
      }

      if (url.pathname.endsWith('/dispatch_mail_worker_probe')) {
        body = 42;
      }

      if (url.pathname.endsWith('/mail_worker_probe_result')) {
        body = ${JSON.stringify(probeResult)};
      }

      return new Response(JSON.stringify(body), {
        status: 200,
        headers: {
          'content-type': 'application/json',
        },
      });
    };

    await import('./scripts/deploy/configure-supabase.mjs');
  `;

  return spawnSync(process.execPath, ["--input-type=module", "-e", code], {
    encoding: "utf8",
    timeout: 5_000,
    env: {
      ...process.env,
      SUPABASE_ACCESS_TOKEN: "access-token",
      SUPABASE_PROJECT_REF: "project-ref",
      NEXT_PUBLIC_SUPABASE_URL: "https://project-ref.supabase.co",
      SUPABASE_SERVICE_ROLE_KEY: "service-key",
      APP_URL: "https://staging.example.invalid",
      EVENT_SLUG: "event",
      CRON_SECRET: "x".repeat(40),
      SEND_EMAIL_HOOK_SECRET: `v1,whsec_${Buffer.alloc(32, 1).toString("base64")}`,
      APP_ENVIRONMENT: "staging",
      REGISTRATION_MODE: "staging_test",
      MAIL_MODE: "allowlist",
      TEST_EMAIL_1: "test@example.nl",
      MAIL_ALLOWED_RECIPIENTS: "test@example.nl,second@example.nl",
      ...environment,
    },
  });
}

describe("mail worker deployment probe", () => {
  it("opens the explicitly authorized live release through the service RPC", () => {
    const result = configure({ found: true, statusCode: 204, timedOut: false, error: null }, 200,
      { APP_ENVIRONMENT: "production", REGISTRATION_MODE: "live", MAIL_MODE: "live", ORGANIZATION_SUPPORT_EMAIL: "test@example.nl" });
    expect(result.status, result.stderr).toBe(0);
    expect(result.stdout).toContain("Supabase release controls configured for production.");
  });
  it("rejects a staging notification recipient outside the allowlist", () => {
    const result = configure({}, 200, { TEST_EMAIL_1: "outside@example.nl" });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("must be configured and allowlisted on staging");
  });

  it("requires successful pg_net reachability and runtime mail gateway validation", () => {
    const result = configure({
      found: true,
      statusCode: 204,
      timedOut: false,
      error: null,
    });

    expect(result.status, result.stderr).toBe(0);
    expect(result.stdout).toContain("Fixed staging notification recipient configured.");
    expect(result.stdout).toContain("Supabase pg_net mail worker probe passed.");
    expect(result.stdout).toContain("Transactional mail gateway runtime probe passed.");
  });

  it("reports rejected CRON authentication precisely", () => {
    const result = configure({
      found: true,
      statusCode: 401,
      timedOut: false,
      error: null,
    });

    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("CRON authentication was rejected");
  });

  it("fails before acceptance when the deployed runtime mail gateway is unavailable", () => {
    const result = configure({
      found: true,
      statusCode: 204,
      timedOut: false,
      error: null,
    }, 503);

    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("runtime configuration is unavailable or disabled");
  });
});
