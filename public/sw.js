const VERSION = "duindorp-public-v2";
const ASSET_CACHE = `${VERSION}:assets`;
const LEGACY_PUBLIC_CACHE_PREFIX = "duindorp-public-";
const PRIVATE_CACHE_PREFIX = "duindorp-private";
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
    return new Response(
      "<!doctype html><html lang=\"nl\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Geen verbinding</title><body><main><h1>Geen verbinding</h1><p>De pagina kon niet worden geladen.</p><p><a href=\"\">Probeer opnieuw</a></p></main></body></html>",
      {
        status: 503,
        headers: {
          "Cache-Control": "no-store",
          "Content-Type": "text/html; charset=utf-8",
        },
      },
    );
  }
}

async function fetchVersionedAsset(request) {
  const cache = await caches.open(ASSET_CACHE);
  const cached = await cache.match(request);
  if (cached) return cached;

  const response = await fetch(request);
  if (response.ok && response.type === "basic") {
    await cache.put(request, response.clone());
  }
  return response;
}

self.addEventListener("install", (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    const legacyPublicCaches = keys.filter(
      (key) => key.startsWith(LEGACY_PUBLIC_CACHE_PREFIX) && key !== ASSET_CACHE,
    );
    const cachesToDelete = keys.filter(
      (key) => legacyPublicCaches.includes(key) || key.startsWith(PRIVATE_CACHE_PREFIX),
    );

    await Promise.all(cachesToDelete.map((key) => caches.delete(key)));
    await self.clients.claim();

    // The former worker could serve stale HTML that referenced deleted CSS chunks.
    // Reload only clients that actually had such a legacy public cache.
    if (legacyPublicCaches.length > 0) {
      const clients = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
      for (const client of clients) {
        // Do not await this navigation from activate: the navigation itself needs
        // the newly activated worker and would otherwise deadlock activation.
        client.navigate(client.url).catch(() => {});
      }
    }
  })());
});

self.addEventListener("message", (event) => {
  if (event.data?.type === "CLEAR_PRIVATE_CACHE") {
    event.waitUntil(
      caches.keys().then((keys) => Promise.all(
        keys.filter((key) => key.startsWith(PRIVATE_CACHE_PREFIX)).map((key) => caches.delete(key)),
      )),
    );
  }
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;

  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;

  if (isPrivatePath(url.pathname)) {
    event.respondWith(fetch(event.request, { cache: "no-store" }));
    return;
  }

  if (event.request.mode === "navigate" || event.request.destination === "document") {
    event.respondWith(fetchDocument(event.request));
    return;
  }

  if (isVersionedAsset(url.pathname)) {
    event.respondWith(fetchVersionedAsset(event.request));
  }
});
