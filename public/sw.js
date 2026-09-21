const VERSION = "duindorp-public-v1";
const PUBLIC_CACHE = `${VERSION}:public`;
const PUBLIC_ASSETS = ["/", "/verhaal", "/werelden", "/faq", "/manifest.webmanifest", "/images/logo.webp", "/images/avondloop-hero.webp"];
const PRIVATE_PREFIXES = ["/mijn-", "/admin", "/api/"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(PUBLIC_CACHE).then((cache) => cache.addAll(PUBLIC_ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== PUBLIC_CACHE).map((key) => caches.delete(key)))).then(() => self.clients.claim()));
});

self.addEventListener("message", (event) => {
  if (event.data?.type === "CLEAR_PRIVATE_CACHE") event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((key) => key.startsWith("duindorp-private")).map((key) => caches.delete(key)))));
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;
  if (PRIVATE_PREFIXES.some((prefix) => url.pathname.startsWith(prefix))) {
    event.respondWith(fetch(event.request, { cache: "no-store" }));
    return;
  }
  event.respondWith(caches.match(event.request).then((cached) => {
    const network = fetch(event.request).then((response) => {
      if (response.ok && response.type === "basic" && !response.headers.get("set-cookie")) caches.open(PUBLIC_CACHE).then((cache) => cache.put(event.request, response.clone()));
      return response;
    });
    return cached ?? network.catch(() => caches.match("/"));
  }));
});
