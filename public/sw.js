const VERSION = "duindorp-public-v3";
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
const PRIVATE_PREFIXES = ["/mijn-", "/omgeving", "/admin", "/api/", "/auth/"];

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
      const cached = await caches.match(OFFLINE_URL);
      return cached || new Response("Geen verbinding", { status: 503, headers: { "Cache-Control": "no-store" } });
    }));
    return;
  }
  if (event.request.mode === "navigate" || event.request.destination === "document") {
    event.respondWith(fetchDocument(event.request));
    return;
  }
  if (isVersionedAsset(url.pathname)) event.respondWith(fetchVersionedAsset(event.request));
});

self.addEventListener("push", (event) => {
  event.waitUntil(self.registration.showNotification("De Duindorpse Poorten", {
    body: "Er staat een nieuwe melding in je persoonlijke omgeving klaar.",
    icon: "/pwa/icons/pwa-192.png",
    badge: "/pwa/icons/pwa-192.png",
    data: { url: "/omgeving" },
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const existing = windows.find((client) => new URL(client.url).origin === self.location.origin);
    if (existing) {
      await existing.navigate("/omgeving");
      return existing.focus();
    }
    return self.clients.openWindow("/omgeving");
  })());
});
