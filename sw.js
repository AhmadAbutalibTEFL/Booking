/* BookMyClass service worker.
   Deliberately small and safe:
   - Only same-origin GET requests are ever handled. Supabase, Google sign-in and CDN scripts are never touched.
   - Pages and API responses are never cached, so no user's bookings or session data can be stored or shown to someone else.
   - Navigations go to the network; if offline, a static offline page is shown (it never pretends a booking happened).
   - Only the offline page, manifest and icons are cached. Bump VERSION to roll out a new cache.
   - A new worker waits until the user taps "Reload" in the app (no surprise reloads mid-booking). */
const VERSION = 'bmc-v1';
const PRECACHE = ['/offline.html', '/manifest.webmanifest', '/icons/icon-192.png', '/icons/icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(PRECACHE)));
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k.startsWith('bmc-') && k !== VERSION) await caches.delete(k);
    await self.clients.claim();
  })());
});

self.addEventListener('message', e => { if (e.data === 'SKIP_WAITING') self.skipWaiting(); });

self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const u = new URL(r.url);
  if (u.origin !== self.location.origin) return;
  if (r.mode === 'navigate') {
    e.respondWith(fetch(r).catch(() => caches.match('/offline.html')));
    return;
  }
  if (u.pathname.startsWith('/icons/') || u.pathname === '/manifest.webmanifest') {
    e.respondWith(caches.match(r).then(hit => hit || fetch(r)));
  }
});
