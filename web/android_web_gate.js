// Android: optional native-app prompt after the web app has loaded — never blocks boot.
(function () {
  var ANDROID_PACKAGE = 'com.u_panel';
  var DEFAULT_WEB_HOST = 'u-panel-2026.web.app';
  var CUSTOM_SCHEME = 'upanel';
  var SKIP_GATE_KEY = 'upanel_skip_native_gate';
  var API_TIMEOUT_MS = 2500;

  function isAndroidMobile() {
    var ua = navigator.userAgent || '';
    return /Android/i.test(ua) && !/Windows/i.test(ua);
  }

  function detectAndroidBrowser() {
    var ua = navigator.userAgent || '';
    if (/Firefox|FxiOS/i.test(ua)) return 'firefox';
    if (/OPR\/|Opera Mini|Opera Mobi/i.test(ua)) return 'opera';
    if (/SamsungBrowser/i.test(ua)) return 'samsung';
    if (/EdgA|EdgiOS/i.test(ua)) return 'edge';
    if (/UCBrowser|UCWEB/i.test(ua)) return 'uc';
    if (/MiuiBrowser|XiaoMi/i.test(ua)) return 'miui';
    if (/; wv\)|Version\/[\d.]+.*Chrome/i.test(ua) && !/Chrome\/[\d.]+ Mobile/i.test(ua)) {
      return 'webview';
    }
    if (/Chrome/i.test(ua)) return 'chrome';
    return 'generic';
  }

  function canUseInstalledRelatedAppsReliably() {
    if (!('getInstalledRelatedApps' in navigator)) return false;
    return detectAndroidBrowser() === 'chrome';
  }

  function pageSuffix() {
    return window.location.pathname + window.location.search + window.location.hash;
  }

  function webHost() {
    var host = (window.location.hostname || '').trim();
    return host || DEFAULT_WEB_HOST;
  }

  function httpsAppLinkUrl() {
    return 'https://' + webHost() + pageSuffix();
  }

  function androidAppUri() {
    return (
      'android-app://' +
      ANDROID_PACKAGE +
      '/https/' +
      webHost() +
      pageSuffix()
    );
  }

  function intentUrlMinimal() {
    return (
      'intent://' +
      webHost() +
      pageSuffix() +
      '#Intent;scheme=https;package=' +
      ANDROID_PACKAGE +
      ';action=android.intent.action.VIEW;category=android.intent.category.BROWSABLE;category=android.intent.category.DEFAULT;end'
    );
  }

  function intentUrlWithFallback(fallbackUrl) {
    var fallback = fallbackUrl || window.location.href;
    return (
      intentUrlMinimal().replace(
        ';end',
        ';S.browser_fallback_url=' +
          encodeURIComponent(fallback) +
          ';end'
      )
    );
  }

  function customSchemeUrl() {
    return CUSTOM_SCHEME + '://open' + pageSuffix();
  }

  var LAUNCH_BUILDERS = {
    'android-app': function () {
      return androidAppUri();
    },
    'custom-scheme': function () {
      return customSchemeUrl();
    },
    'https-app-link': function () {
      return httpsAppLinkUrl();
    },
    intent: function () {
      return intentUrlWithFallback();
    },
    'intent-minimal': function () {
      return intentUrlMinimal();
    },
  };

  var LAUNCH_ORDER = {
    chrome: ['intent', 'https-app-link', 'android-app', 'custom-scheme'],
    opera: ['custom-scheme', 'https-app-link', 'intent-minimal', 'android-app'],
    firefox: ['android-app', 'custom-scheme', 'https-app-link', 'intent-minimal'],
    samsung: ['intent', 'https-app-link', 'custom-scheme', 'android-app'],
    edge: ['intent', 'https-app-link', 'android-app', 'custom-scheme'],
    uc: ['custom-scheme', 'android-app', 'https-app-link', 'intent-minimal'],
    miui: ['custom-scheme', 'https-app-link', 'android-app', 'intent-minimal'],
    webview: ['custom-scheme', 'android-app', 'https-app-link', 'intent-minimal'],
    generic: ['custom-scheme', 'android-app', 'https-app-link', 'intent-minimal'],
  };

  function navigateTo(url) {
    try {
      window.location.assign(url);
    } catch (_) {
      try {
        window.location.href = url;
      } catch (__) {}
    }
  }

  function openNativeApp(options) {
    var opts = options || {};
    var browser = opts.browser || detectAndroidBrowser();
    var order = opts.order || LAUNCH_ORDER[browser] || LAUNCH_ORDER.generic;
    var key = order[0];
    var build = LAUNCH_BUILDERS[key];
    if (!build) return;
    navigateTo(build());
  }

  function shouldSkipNativeGate() {
    try {
      return sessionStorage.getItem(SKIP_GATE_KEY) === '1';
    } catch (_) {
      return false;
    }
  }

  function rememberSkipNativeGate() {
    try {
      sessionStorage.setItem(SKIP_GATE_KEY, '1');
    } catch (_) {}
  }

  function hideNativeGate() {
    window.__upanelNativeGateShown = false;
    var overlay = document.getElementById('upanel-native-overlay');
    if (overlay && overlay.parentNode) {
      overlay.parentNode.removeChild(overlay);
    }
  }

  function brandedGateHtml() {
    if (window.upanelBrand && window.upanelBrand.gateScreenHtml) {
      return window.upanelBrand.gateScreenHtml();
    }
    return '<p style="text-align:center;padding:24px;">Open U-Panel app</p>';
  }

  function showFullScreenOverlay(html) {
    var overlay = document.getElementById('upanel-native-overlay');
    if (!overlay) {
      overlay = document.createElement('div');
      overlay.id = 'upanel-native-overlay';
      overlay.style.cssText =
        'position:fixed;inset:0;z-index:100000;overflow:auto;';
      document.body.appendChild(overlay);
    }
    overlay.innerHTML = html;
  }

  function showGate() {
    if (shouldSkipNativeGate()) return;

    window.__upanelNativeGateShown = true;
    document.title = 'Open U-Panel app';
    showFullScreenOverlay(brandedGateHtml());

    var browser = detectAndroidBrowser();
    var openBtn = document.getElementById('upanel-open-native');
    if (openBtn) {
      openBtn.addEventListener('click', function () {
        openNativeApp({ browser: browser });
      });
    }

    var continueBtn = document.getElementById('upanel-continue-web');
    if (continueBtn) {
      continueBtn.addEventListener('click', function () {
        rememberSkipNativeGate();
        hideNativeGate();
      });
    }
  }

  function withTimeout(promise, ms) {
    return new Promise(function (resolve, reject) {
      var done = false;
      var timer = window.setTimeout(function () {
        if (done) return;
        done = true;
        reject(new Error('timeout'));
      }, ms);
      promise.then(
        function (value) {
          if (done) return;
          done = true;
          window.clearTimeout(timer);
          resolve(value);
        },
        function (err) {
          if (done) return;
          done = true;
          window.clearTimeout(timer);
          reject(err);
        }
      );
    });
  }

  function checkNativeInstalledViaApi() {
    if (shouldSkipNativeGate()) return;

    withTimeout(navigator.getInstalledRelatedApps(), API_TIMEOUT_MS)
      .then(function (apps) {
        if (!Array.isArray(apps)) return;
        var installed = apps.some(function (app) {
          return app && app.id === ANDROID_PACKAGE;
        });
        if (installed) {
          showGate();
        }
      })
      .catch(function () {
        // Missing API, timeout, or permission denied — keep using the web app.
      });
  }

  function scheduleInstallCheck() {
    if (!isAndroidMobile()) return;
    if (!canUseInstalledRelatedAppsReliably()) return;

    function runCheck() {
      checkNativeInstalledViaApi();
    }

    if (window.__upanelSplashHidden) {
      window.setTimeout(runCheck, 300);
      return;
    }
    window.addEventListener(
      'flutter-first-frame',
      function () {
        window.setTimeout(runCheck, 300);
      },
      { once: true }
    );
  }

  scheduleInstallCheck();
})();
