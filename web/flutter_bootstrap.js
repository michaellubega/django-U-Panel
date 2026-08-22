{{flutter_js}}
{{flutter_build_config}}

// Load CanvasKit from bundled canvaskit/ under the page <base href> (e.g. /app/canvaskit/).
(function () {
  var baseEl = document.querySelector('base');
  var root = (baseEl && baseEl.getAttribute('href')) || '/';
  if (!root.endsWith('/')) root += '/';
  _flutter.loader.load({
    config: {
      canvasKitBaseUrl: root + 'canvaskit/',
    },
  });
})();
