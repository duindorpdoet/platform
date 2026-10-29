export type PublicationReason = { code: string; message: string; action: "settings" | "portals" | "points" | "planning"; field?: string };
export type PublicationReadiness = { ready: boolean; reasons: PublicationReason[]; routeSettingsVersion: number | null; eventSettingsVersion: number | null };

/** Keep the server's concrete reason and setting together, including RPC errors. */
export function readinessFromError(details?: string | null): PublicationReadiness | null {
  if (!details) return null;
  try {
    const value = JSON.parse(details) as PublicationReadiness;
    return typeof value.ready === "boolean" && Array.isArray(value.reasons)
      && value.reasons.every(reason => typeof reason.code === "string" && typeof reason.message === "string") ? value : null;
  } catch { return null; }
}

export function mergeReadiness(...values: Array<PublicationReadiness | null | undefined>) {
  return [...new Map(values.flatMap(value => value?.reasons ?? []).map(reason => [reason.code, reason])).values()];
}
