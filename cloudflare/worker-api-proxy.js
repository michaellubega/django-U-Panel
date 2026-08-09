/**
 * Cloudflare Worker — proxy /api and /admin to the U-Panel VPS while keeping
 * the rest of kiu.orion13.us on GitHub Pages.
 *
 * Setup (Cloudflare dashboard):
 * 1. Add zone orion13.us (free plan).
 * 2. DNS: kiu → CNAME michaellubega.github.io (Proxied ON).
 * 3. Workers → Create → paste this file → Deploy.
 * 4. Workers → Triggers → Add route:
 *      kiu.orion13.us/api/*
 *      kiu.orion13.us/admin/*
 * 5. SSL/TLS → Flexible (HTTPS to users, HTTP to 169.58.135.136:80).
 *
 * Then https://kiu.orion13.us/app/ calls https://kiu.orion13.us/api/ (same origin).
 */
const ORIGIN = 'http://169.58.135.136';

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (!path.startsWith('/api/') && !path.startsWith('/admin/')) {
      return fetch(request);
    }

    const target = `${ORIGIN}${path}${url.search}`;
    const headers = new Headers(request.headers);
    headers.set('Host', '169.58.135.136');

    const init = {
      method: request.method,
      headers,
      redirect: 'follow',
    };
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      init.body = request.body;
    }

    return fetch(target, init);
  },
};
