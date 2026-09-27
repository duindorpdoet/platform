import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { z } from "zod";
import { assertTrustedOrigin } from "@/lib/http/api";
import { createClient } from "@/lib/supabase/server";
import { serverEnv } from "@/lib/config/server-env";
import {
  codeDigest,
  decryptValue,
  encryptValue,
  generateChildCode,
  newSessionToken,
  subjectDigest,
  tokenHash,
} from "@/lib/poortenboek/crypto";
import {
  LOGIN_ERROR,
  normalizeCode,
  validCode,
  type DemoPhase,
} from "@/lib/poortenboek/model";
import { demoSnapshot, newDemoSession } from "@/lib/poortenboek/demo";
import {
  canDemo,
  CHILD_COOKIE,
  childRpc,
  childSecrets,
  childSnapshot,
  cookieOptions,
  DEMO_COOKIE,
  DEVICE_COOKIE,
  privateHeaders,
  readDemo,
  writeDemo,
} from "@/lib/poortenboek/server";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";
type Context = { params: Promise<{ action: string }> };
const response = (data: unknown, status = 200) =>
  NextResponse.json(data, { status, headers: privateHeaders });
const errorResponse = (message: string, status: number) =>
  response({ error: message }, status);
async function body(request: Request) {
  if (Number(request.headers.get("content-length") ?? 0) > 8192)
    throw new Error("INVALID_INPUT");
  const reader = request.body?.getReader();
  if (!reader) throw new Error("INVALID_INPUT");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 8192) {
        await reader.cancel();
        throw new Error("INVALID_INPUT");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}
async function parentActor() {
  const client = await createClient();
  const result = await client?.auth.getUser();
  if (!result?.data.user || result.error) throw new Error("NOT_AUTHORIZED");
  return result.data.user.id;
}
export async function GET(_request: Request, context: Context) {
  const { action } = await context.params;
  try {
    if (action === "parent")
      return response(
        await childRpc("poortenboek_parent", {
          _actor: await parentActor(),
          _event_slug: serverEnv().EVENT_SLUG,
          _action: "list",
        }),
      );
    if (action === "admin")
      return response(
        await childRpc("poortenboek_admin", {
          _actor: await parentActor(),
          _event_slug: serverEnv().EVENT_SLUG,
          _action: "snapshot",
        }),
      );
    if (!["snapshot", "entry"].includes(action))
      return errorResponse("Niet gevonden", 404);
    const snapshot = await childSnapshot();
    if (action === "entry")
      return response({ authenticated: Boolean(snapshot) });
    return snapshot
      ? response(snapshot)
      : errorResponse("Open opnieuw jouw Poortenboek.", 401);
  } catch (error) {
    const denied =
      error instanceof Error &&
      /NOT_AUTHORIZED|CHILD_SESSION_INVALID/.test(error.message);
    return errorResponse(
      denied
        ? "Open opnieuw jouw Poortenboek."
        : "Even geen verbinding. Probeer opnieuw.",
      denied ? 401 : 503,
    );
  }
}
export async function POST(request: Request, context: Context) {
  const { action } = await context.params;
  const store = await cookies();
  try {
    assertTrustedOrigin(request);
    const input = await body(request);
    if (action === "login") {
      const { code: raw } = z.object({ code: z.string().max(32) }).parse(input);
      const code = normalizeCode(raw);
      // This exception is server-only, doubly gated, and never consults real child data.
      if (canDemo() && code === "DEMO26") {
        await writeDemo(newDemoSession(Date.now()));
        store.set(CHILD_COOKIE, "", { ...cookieOptions, maxAge: 0 });
        return response({ ok: true });
      }
      const secrets = childSecrets();
      let device = store.get(DEVICE_COOKIE)?.value;
      if (!device || !/^[A-Za-z0-9_-]{43}$/.test(device))
        device = newSessionToken();
      store.set(DEVICE_COOKIE, device, {
        ...cookieOptions,
        expires: new Date(Date.now() + 30 * 86_400_000),
      });
      const token = newSessionToken();
      const result = await childRpc("poortenboek_login", {
        _digest: codeDigest(validCode(code) ? code : "invalid", secrets.pepper),
        _token_hash: tokenHash(token),
        _ip_hash: subjectDigest(
          "ip",
          // The ingress appends its observed client IP. Ignore caller-supplied
          // prefixes and X-Real-IP; a missing proxy header shares a strict bucket.
          request.headers.get("x-forwarded-for")?.split(",").at(-1)?.trim() ||
            "unknown",
          secrets.pepper,
        ),
        _device_hash: subjectDigest("device", device, secrets.pepper),
      });
      if (!result.ok) {
        await new Promise((resolve) =>
          setTimeout(resolve, Math.min(650, Number(result.delayMs) || 250)),
        );
        return errorResponse(LOGIN_ERROR, 400);
      }
      store.set(CHILD_COOKIE, token, {
        ...cookieOptions,
        expires: new Date(result.expiresAt),
      });
      store.set(DEMO_COOKIE, "", { ...cookieOptions, maxAge: 0 });
      return response({ ok: true });
    }
    if (action === "parent") {
      const data = z
        .object({
          action: z.enum(["open", "view", "renew", "revoke", "reset"]),
          childId: z.uuid(),
          reason: z.string().min(10).max(500).optional(),
        })
        .parse(input);
      const token = data.action === "open" ? newSessionToken() : null;
      const previousToken = store.get(CHILD_COOKIE)?.value;
      const rpcName = token ? "poortenboek_parent_open" : "poortenboek_parent";
      const args = {
        _actor: await parentActor(),
        _event_slug: serverEnv().EVENT_SLUG,
        _child_id: data.childId,
        ...(token
          ? {
              _token_hash: tokenHash(token),
              _previous_token_hash:
                previousToken && /^[A-Za-z0-9_-]{43}$/.test(previousToken)
                  ? tokenHash(previousToken)
                  : null,
            }
          : { _action: data.action, _reason: data.reason ?? null }),
      };
      let result = await childRpc(rpcName, args);
      if (result.needsCode) {
        const { pepper, encryptionKey } = childSecrets();
        for (let attempt = 0; attempt < 12; attempt++) {
          const code = generateChildCode();
          try {
            result = await childRpc(rpcName, {
              ...args,
              _digest: codeDigest(code, pepper),
              _ciphertext: encryptValue(
                code,
                encryptionKey,
                `${result.eventId}:${data.childId}`,
              ),
            });
            break;
          } catch (error) {
            if (
              !(error instanceof Error) ||
              !("code" in error) ||
              error.code !== "23505" ||
              attempt === 11
            )
              throw error;
          }
        }
      }
      if (token) {
        if (!result.ok || !result.expiresAt) throw new Error("INVALID_SESSION");
        store.set(CHILD_COOKIE, token, {
          ...cookieOptions,
          expires: new Date(result.expiresAt),
        });
        store.set(DEMO_COOKIE, "", { ...cookieOptions, maxAge: 0 });
        return response({ ok: true });
      }
      if (result.ciphertext)
        return response({
          code: decryptValue(
            result.ciphertext,
            childSecrets().encryptionKey,
            `${result.eventId}:${data.childId}`,
          ),
        });
      return response({ ok: true });
    }
    if (action === "admin") {
      const data = z
        .object({
          action: z.enum(["save", "reset"]),
          payload: z.record(z.string(), z.unknown()),
        })
        .parse(input);
      return response(
        await childRpc("poortenboek_admin", {
          _actor: await parentActor(),
          _event_slug: serverEnv().EVENT_SLUG,
          _action: data.action,
          _payload: data.payload,
        }),
      );
    }
    if (
      ![
        "welcome",
        "logout",
        "checklist",
        "vote",
        "sound",
        "demo-phase",
      ].includes(action)
    )
      return errorResponse("Niet gevonden", 404);
    if (action === "checklist")
      z.object({ values: z.array(z.boolean()).length(6) }).parse(input);
    if (action === "sound") z.object({ enabled: z.boolean() }).parse(input);
    if (action === "vote")
      z.object({
        electionId: z.string().max(80),
        round: z.enum(["direct", "round_one", "round_two"]),
        choices: z.array(z.string().max(80)).min(1).max(3),
        requestId: z.uuid(),
      }).parse(input);
    if (action === "demo-phase" && !canDemo())
      return errorResponse("Niet gevonden", 404);
    const demo = await readDemo();
    if (action === "logout") {
      const token = store.get(CHILD_COOKIE)?.value;
      if (token && !demo) {
        try {
          await childRpc("poortenboek_child_action", {
            _token_hash: tokenHash(token),
            _action: "logout",
          });
        } catch (error) {
          if (
            !(error instanceof Error) ||
            !error.message.includes("CHILD_SESSION_INVALID")
          )
            throw error;
        }
      }
      store.set(CHILD_COOKIE, "", { ...cookieOptions, maxAge: 0 });
      store.set(DEMO_COOKIE, "", { ...cookieOptions, maxAge: 0 });
      return response({ ok: true });
    }
    if (demo) {
      if (action === "welcome") demo.welcomeSeen = true;
      if (action === "checklist") demo.checklist = input.values;
      if (action === "sound") demo.sound = input.enabled;
      if (action === "vote") {
        const election = demoSnapshot(demo).election;
        if (
          !election.open ||
          input.round !== election.phase ||
          input.choices.length !== (election.phase === "round_one" ? 3 : 1) ||
          new Set(input.choices).size !== input.choices.length ||
          input.choices.some(
            (id: string) =>
              !election.options.some((option) => option.id === id),
          )
        )
          throw new Error("INVALID_OPTIONS");
        demo.choices = input.choices;
      }
      if (action === "demo-phase") {
        demo.phase = z
          .enum(["empty", "three", "all", "finalists", "winner", "prepared"])
          .parse(input.phase) as DemoPhase;
        demo.choices = [];
        if (demo.phase === "prepared") demo.checklist = Array(6).fill(true);
      }
      await writeDemo(demo);
      return response(demoSnapshot(demo));
    }
    if (action === "demo-phase") return errorResponse("Niet gevonden", 404);
    const token = store.get(CHILD_COOKIE)?.value;
    if (!token) return errorResponse("Open opnieuw jouw Poortenboek.", 401);
    return response(
      await childRpc("poortenboek_child_action", {
        _token_hash: tokenHash(token),
        _action: action,
        _payload: input,
        _request_id: input.requestId ?? null,
      }),
    );
  } catch (error) {
    // Never log request bodies, codes, ciphertext, session cookies or raw database errors.
    if (action === "login") return errorResponse(LOGIN_ERROR, 400);
    const message = error instanceof Error ? error.message : "";
    if (/NOT_AUTHORIZED|CHILD_SESSION_INVALID/.test(message))
      return errorResponse("Open opnieuw jouw Poortenboek.", 401);
    if (/VOTING_CLOSED/.test(message))
      return errorResponse(
        "Deze stemronde is veranderd of gesloten. Bekijk de nieuwe stand.",
        409,
      );
    if (/OPTION_IN_USE/.test(message))
      return errorResponse(
        "Deze naam is al onderdeel van een verkiezing en blijft behouden.",
        409,
      );
    if (/ELECTION_LOCKED/.test(message))
      return errorResponse(
        "De organisatorische sluitingsdatum is bereikt.",
        409,
      );
    return errorResponse(
      "Dit kon niet worden opgeslagen. Controleer je keuze en probeer opnieuw.",
      400,
    );
  }
}
