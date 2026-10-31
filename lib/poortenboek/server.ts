import "server-only";
import { withBookStories } from "./serialization";
import { cookies } from "next/headers";
import { createPrivilegedClient } from "@/lib/supabase/privileged";
import { serverEnv } from "@/lib/config/server-env";
import { decryptValue, encryptValue, tokenHash } from "./crypto";
import { demoEnabled, type BookSnapshot } from "./model";
import { demoSnapshot, type DemoSession } from "./demo";

export const CHILD_COOKIE = "__Host-poortenboek-session";
export const DEMO_COOKIE = "__Host-poortenboek-demo";
export const DEVICE_COOKIE = "__Host-poortenboek-device";
export const privateHeaders = {
  "Cache-Control": "private, no-store, max-age=0",
  "X-Robots-Tag": "noindex, nofollow",
  Vary: "Cookie",
};
export const cookieOptions = {
  secure: true,
  httpOnly: true,
  sameSite: "lax" as const,
  path: "/",
};
export const canDemo = () =>
  demoEnabled(
    serverEnv().APP_ENVIRONMENT,
    serverEnv().POORTENBOEK_DEMO_ENABLED,
  );
export function childSecrets() {
  const env = serverEnv();
  if (!env.CHILD_CODE_PEPPER || !env.CHILD_CODE_ENCRYPTION_KEY)
    throw new Error("Child credential configuration unavailable");
  return {
    pepper: env.CHILD_CODE_PEPPER,
    encryptionKey: env.CHILD_CODE_ENCRYPTION_KEY,
  };
}
export async function childRpc(
  name: string,
  args: Record<string, unknown>,
  signal?: AbortSignal,
) {
  signal?.throwIfAborted();
  const client = createPrivilegedClient();
  if (!client) throw new Error("Poortenboek service unavailable");
  const request = client.schema("api").rpc(name, args);
  if (signal) request.abortSignal(signal);
  const result = await request;
  signal?.throwIfAborted();
  if (result.error)
    throw Object.assign(new Error(result.error.message), {
      code: result.error.code,
    });
  return withBookStories(result.data);
}
export async function readDemo() {
  if (!canDemo()) return null;
  const value = (await cookies()).get(DEMO_COOKIE)?.value;
  if (!value) return null;
  try {
    const session = JSON.parse(
      decryptValue(value, childSecrets().encryptionKey, "staging-demo"),
    ) as DemoSession;
    if (
      session.expiresAt <= Date.now() ||
      session.expiresAt !== session.createdAt + 43_200_000
    )
      return null;
    return session;
  } catch {
    return null;
  }
}
export async function writeDemo(session: DemoSession) {
  if (!canDemo()) throw new Error("Demo unavailable");
  (await cookies()).set(
    DEMO_COOKIE,
    encryptValue(
      JSON.stringify(session),
      childSecrets().encryptionKey,
      "staging-demo",
    ),
    { ...cookieOptions, expires: new Date(session.expiresAt) },
  );
}
export async function childSnapshot(
  signal?: AbortSignal,
): Promise<BookSnapshot | null> {
  signal?.throwIfAborted();
  const demo = await readDemo();
  signal?.throwIfAborted();
  if (demo) return withBookStories(demoSnapshot(demo));
  const token = (await cookies()).get(CHILD_COOKIE)?.value;
  signal?.throwIfAborted();
  if (!token || !/^[A-Za-z0-9_-]{43}$/.test(token)) return null;
  const controller = new AbortController();
  const abort = () => controller.abort(signal?.reason);
  signal?.addEventListener("abort", abort, { once: true });
  // Bound only snapshot HTTP work. Aborting fetch does not prove that the
  // database transaction has stopped; the serial client queue limits demand.
  const timeout = setTimeout(
    () => controller.abort(new DOMException("Snapshot timed out", "TimeoutError")),
    15_000,
  );
  try {
    return (await childRpc(
      "poortenboek_child_action",
      { _token_hash: tokenHash(token), _action: "snapshot" },
      controller.signal,
    )) as BookSnapshot;
  } catch (error) {
    if (
      error instanceof Error &&
      error.message.includes("CHILD_SESSION_INVALID")
    )
      return null;
    throw error;
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener("abort", abort);
  }
}
