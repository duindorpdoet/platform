export type AnalyticsSurface =
  | "participant"
  | "group"
  | "homeowner"
  | "child"
  | "admin"
  | "editorial"
  | "share_studio"
  | "unknown";

export type AnalyticsEventType =
  | "login_completed"
  | "environment_opened"
  | "pwa_install_prompt_accepted"
  | "pwa_install_completed"
  | "pwa_install_manual_confirmed"
  | "pwa_standalone_opened";

const sessionKey = "poorten:analytics-session";

export function analyticsSurfaceForPath(path: string): AnalyticsSurface {
  if (path.startsWith("/admin")) return "admin";
  if (path.startsWith("/mijn-huis") || path.startsWith("/omgeving/huiseigenaar")) return "homeowner";
  if (path.startsWith("/mijn-groep") || path.startsWith("/omgeving/meeloper")) return "group";
  if (path.startsWith("/poortenboek")) return "child";
  if (path.startsWith("/deel-de-magie")) return "share_studio";
  if (path.startsWith("/omgeving/communicatie")) return "editorial";
  if (path.startsWith("/omgeving") || path.startsWith("/mijn-inschrijving")) return "participant";
  return "unknown";
}

export function analyticsSessionId() {
  try {
    const existing = window.sessionStorage.getItem(sessionKey);
    if (existing) return existing;
    const value = crypto.randomUUID();
    window.sessionStorage.setItem(sessionKey, value);
    return value;
  } catch {
    return crypto.randomUUID();
  }
}

export function analyticsDeviceMetadata() {
  const standalone = window.matchMedia("(display-mode: standalone)").matches
    || (navigator as Navigator & { standalone?: boolean }).standalone === true;
  const platform = /iPhone|iPad|iPod/i.test(navigator.userAgent)
    ? "ios"
    : /Android/i.test(navigator.userAgent)
      ? "android"
      : /Mac|Win|Linux/i.test(navigator.platform)
        ? "desktop"
        : "other";
  return { platform, displayMode: standalone ? "standalone" : "browser" } as const;
}

export async function trackProductAnalytics(
  eventType: AnalyticsEventType,
  surface?: AnalyticsSurface,
  metadata: Partial<ReturnType<typeof analyticsDeviceMetadata>> = {},
) {
  if (typeof window === "undefined") return;
  try {
    await fetch("/api/analytics/events", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        eventType,
        surface: surface ?? analyticsSurfaceForPath(window.location.pathname),
        sessionId: eventType === "login_completed" ? crypto.randomUUID() : analyticsSessionId(),
        metadata,
      }),
      keepalive: true,
    });
  } catch {
    // Product analytics never blocks authentication, navigation or installation.
  }
}
