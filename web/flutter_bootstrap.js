{{flutter_js}}
{{flutter_build_config}}

// Load CanvasKit from bundled /canvaskit/ (not gstatic CDN) so boot works on
// slow or restricted networks.
// No serviceWorkerSettings — Firebase Hosting cache headers handle assets;
// Flutter's deprecated SW caused MIME/caching issues when files were missing.
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: '/canvaskit/',
  },
});
