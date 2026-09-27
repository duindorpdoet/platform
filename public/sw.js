const VERSION = "duindorp-public-v6";
const ASSET_CACHE = `${VERSION}:assets`;
const LEGACY_PUBLIC_CACHE_PREFIX = "duindorp-public-";
const PRIVATE_CACHE_PREFIX = "duindorp-private";
const OFFLINE_URL = "/offline.html";
const SAFE_ASSETS = [
  OFFLINE_URL,
  "/favicon.svg",
  "/manifest.webmanifest",
  "/images/logo.webp",
  "/pwa/icons/apple-touch-icon-180.png",
  "/pwa/icons/pwa-192.png",
  "/pwa/icons/pwa-512.png",
  "/pwa/icons/maskable-512.png",
];
const PRIVATE_PREFIXES = ["/mijn-", "/omgeving", "/admin", "/api/", "/auth/", "/poortenboek", "/uitnodiging", "/nachtpost"];

function isPrivatePath(pathname) {
  return PRIVATE_PREFIXES.some((prefix) => pathname.startsWith(prefix));
}

function isVersionedAsset(pathname) {
  return pathname.startsWith("/_next/static/");
}

async function fetchDocument(request) {
  try {
    return await fetch(request, { cache: "no-store" });
  } catch {
    const cached = await caches.match(OFFLINE_URL);
    return cached || new Response("Geen verbinding", {
      status: 503,
      headers: { "Cache-Control": "no-store", "Content-Type": "text/plain; charset=utf-8" },
    });
  }
}

async function fetchVersionedAsset(request) {
  const cache = await caches.open(ASSET_CACHE);
  const cached = await cache.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  if (response.ok && response.type === "basic") await cache.put(request, response.clone());
  return response;
}

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(ASSET_CACHE).then((cache) => cache.addAll(SAFE_ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    const legacyPublicCaches = keys.filter((key) => key.startsWith(LEGACY_PUBLIC_CACHE_PREFIX) && key !== ASSET_CACHE);
    const cachesToDelete = keys.filter((key) => legacyPublicCaches.includes(key) || key.startsWith(PRIVATE_CACHE_PREFIX));
    await Promise.all(cachesToDelete.map((key) => caches.delete(key)));
    await self.clients.claim();

    if (legacyPublicCaches.length > 0) {
      const clients = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
      for (const client of clients) client.navigate(client.url).catch(() => {});
    }
  })());
});

self.addEventListener("message", (event) => {
  if (event.data?.type === "CLEAR_PRIVATE_CACHE") {
    event.waitUntil(caches.keys().then((keys) => Promise.all(
      keys.filter((key) => key.startsWith(PRIVATE_CACHE_PREFIX)).map((key) => caches.delete(key)),
    )));
  }
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;

  if (isPrivatePath(url.pathname)) {
    event.respondWith(fetch(event.request, { cache: "no-store" }).catch(async () => {
      const headers = { "Cache-Control": "private, no-store, max-age=0", "X-Robots-Tag": "noindex, nofollow" };
      if (event.request.mode !== "navigate") return new Response(JSON.stringify({ error: "Geen verbinding" }), { status: 503, headers: { ...headers, "Content-Type": "application/json" } });
      const cached = await caches.match(OFFLINE_URL);
      return new Response(cached ? await cached.text() : "Geen verbinding", { status: 503, headers: { ...headers, "Content-Type": "text/html; charset=utf-8" } });
    }));
    return;
  }
  if (event.request.mode === "navigate" || event.request.destination === "document") {
    event.respondWith(fetchDocument(event.request));
    return;
  }
  if (isVersionedAsset(url.pathname)) event.respondWith(fetchVersionedAsset(event.request));
});

function safeNewsUrl(value) { return typeof value === "string" && /^\/omgeving\/nieuws\/[a-z0-9]+(?:-[a-z0-9]+)*(?:\?push=[a-f0-9-]{36}(?:&device=[a-f0-9-]{36})?)?$/.test(value) ? value : null; }

self.addEventListener("push", (event) => {
  let payload = {};
  try { payload = event.data?.json() ?? {}; } catch { /* Generic notification if a provider sent malformed data. */ }
  const portal = payload.url === "/mijn-huis";
  const news = safeNewsUrl(payload.url);
  event.waitUntil(self.registration.showNotification(portal ? "De Poortkamer" : "De Duindorpse Poorten", {
    body: portal && typeof payload.body === "string" ? payload.body.slice(0, 240) : news ? "Er staat een nieuw bericht voor je klaar." : "Er staat een nieuwe melding in je persoonlijke omgeving klaar.",
    tag: (portal || news) && typeof payload.tag === "string" ? payload.tag.slice(0, 120) : undefined,
    icon: "/pwa/icons/pwa-192.png",
    badge: "/pwa/icons/pwa-192.png",
    data: { url: portal ? "/mijn-huis" : news || "/omgeving" },
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const destination = event.notification.data?.url === "/mijn-huis" ? "/mijn-huis" : safeNewsUrl(event.notification.data?.url) || "/omgeving";
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const existing = windows.find((client) => new URL(client.url).origin === self.location.origin);
    if (existing) {
      await existing.navigate(destination);
      return existing.focus();
    }
    return self.clients.openWindow(destination);
  })());
});
