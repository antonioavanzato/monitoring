/**
 * Service Worker.
 *  - статика (HTML/CSS/JS/иконки/манифест) — cache-first + фоновое обновление;
 *  - запросы к API (CM_CONFIG.API_BASE) — network-only, НИКОГДА не кэшируются:
 *    в них ездит Authorization: Bearer и приватные метрики.
 */
const VERSION = 'v3';
const STATIC_CACHE = 'cm-static-' + VERSION;

const PRECACHE = [
  './',
  './index.html',
  './login.html',
  './styles.css',
  './config.js',
  './auth.js',
  './app.js',
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-maskable-512.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(STATIC_CACHE)
      // addAll падает целиком при одном 404 — кладём по одному
      .then((cache) => Promise.all(
        PRECACHE.map((url) => cache.add(url).catch(() => null))
      ))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((k) => k.startsWith('cm-') && k !== STATIC_CACHE)
            .map((k) => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // Чужой origin (в т.ч. backend-функция) — мимо кэша.
  if (url.origin !== self.location.origin) return;

  // Навигация: сеть с фолбэком в кэш (чтобы офлайн открывалась оболочка).
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(STATIC_CACHE).then((c) => c.put(req, copy));
          return res;
        })
        .catch(() => caches.match(req).then((hit) => hit || caches.match('./index.html')))
    );
    return;
  }

  // Ассеты: cache-first, обновление в фоне.
  event.respondWith(
    caches.match(req).then((hit) => {
      const network = fetch(req).then((res) => {
        if (res && res.ok && res.type === 'basic') {
          const copy = res.clone();
          caches.open(STATIC_CACHE).then((c) => c.put(req, copy));
        }
        return res;
      }).catch(() => hit);
      return hit || network;
    })
  );
});

self.addEventListener('message', (event) => {
  if (event.data === 'SKIP_WAITING') self.skipWaiting();
});
