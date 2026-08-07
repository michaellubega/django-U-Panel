// Shared U-Panel logo + loading markup for web splash and Android gate screens.
(function (global) {
  var LOGO_SRC = 'icons/Icon-192.png';
  var LOGO_FALLBACK = 'favicon.png';
  var THEME = '#0175C2';

  var SPINNER_CSS =
    '@keyframes upanel-spin{to{transform:rotate(360deg)}}' +
    '.upanel-brand-wrap{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;' +
    'min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;' +
    'background:linear-gradient(165deg,#f4f8fc 0%,#e8f0f8 100%);color:#102033;text-align:center;}' +
    '.upanel-brand-inner{max-width:420px;width:100%;}' +
    '.upanel-brand-logo{width:72px;height:72px;border-radius:18px;object-fit:cover;display:block;' +
    'margin:0 auto 20px;box-shadow:0 8px 24px rgba(1,117,194,0.28);background:#fff;}' +
    '.upanel-brand-spinner{width:36px;height:36px;border:3px solid rgba(1,117,194,0.18);' +
    'border-top-color:' +
    THEME +
    ';border-radius:50%;margin:0 auto;animation:upanel-spin 0.75s linear infinite;}' +
    '.upanel-brand-title{margin:0 0 12px;font-size:22px;font-weight:600;}' +
    '.upanel-brand-text{margin:0 0 24px;line-height:1.5;color:#425466;}' +
    '.upanel-brand-btn{width:100%;border:0;border-radius:12px;padding:14px 18px;font-size:16px;' +
    'font-weight:600;background:' +
    THEME +
    ';color:#fff;cursor:pointer;margin-bottom:10px;}' +
    '.upanel-brand-btn-secondary{width:100%;border:0;border-radius:12px;padding:12px 18px;font-size:15px;' +
    'font-weight:600;background:transparent;color:' +
    THEME +
    ';cursor:pointer;text-decoration:underline;}' +
    '.upanel-brand-hint{margin:18px 0 0;font-size:13px;color:#667788;}';

  function logoImgHtml() {
    return (
      '<img class="upanel-brand-logo" src="' +
      LOGO_SRC +
      '" alt="U-Panel" width="72" height="72" ' +
      'onerror="this.onerror=null;this.src=\'' +
      LOGO_FALLBACK +
      "';\">"
    );
  }

  function loadingScreenHtml(statusText) {
    return (
      '<style>' +
      SPINNER_CSS +
      '</style>' +
      '<div class="upanel-brand-wrap"><div class="upanel-brand-inner">' +
      logoImgHtml() +
      '<div class="upanel-brand-spinner" aria-hidden="true"></div>' +
      '<p class="upanel-brand-text" style="margin-top:20px;margin-bottom:0;font-weight:500;">' +
      statusText +
      '</p></div></div>'
    );
  }

  function gateScreenHtml() {
    return (
      '<style>' +
      SPINNER_CSS +
      '</style>' +
      '<div class="upanel-brand-wrap"><div class="upanel-brand-inner">' +
      logoImgHtml() +
      '<h1 class="upanel-brand-title">Open U-Panel in the app</h1>' +
      '<p class="upanel-brand-text">You have the U-Panel Android app installed. Open it for the best experience, or continue here in your browser.</p>' +
      '<button id="upanel-open-native" type="button" class="upanel-brand-btn">Open U-Panel app</button>' +
      '<button id="upanel-continue-web" type="button" class="upanel-brand-btn-secondary">Continue in browser</button>' +
      '<p class="upanel-brand-hint">If the app does not open, use Continue in browser.</p>' +
      '</div></div>'
    );
  }

  global.upanelBrand = {
    logoSrc: LOGO_SRC,
    theme: THEME,
    logoImgHtml: logoImgHtml,
    loadingScreenHtml: loadingScreenHtml,
    gateScreenHtml: gateScreenHtml,
  };
})(window);
