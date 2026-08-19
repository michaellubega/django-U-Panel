'use strict';
// U-Panel: unregister any legacy Flutter service worker (no offline cache).
self.addEventListener('install', (event) => {
  self.skipWaiting();
});
self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      try {
        await self.registration.unregister();
      } catch (_) {}
    })(),
  );
});
