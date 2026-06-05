const WEB_APP_URL = 'https://u-panel-2026.web.app/';
const WEB_APP_ALT_HOST = 'u-panel-2026.firebaseapp.com';

function applyWebButton(button, noteEl, url, alternateUrl) {
  if (!button) return;

  button.href = url || WEB_APP_URL;
  button.classList.remove('is-disabled');
  button.removeAttribute('aria-disabled');

  if (noteEl) {
    if (alternateUrl) {
      noteEl.textContent =
        'Also at ' + WEB_APP_ALT_HOST + ' — same app, no install.';
    } else {
      noteEl.textContent =
        'Runs in your browser — same sign-in as the mobile app.';
    }
  }
}

async function loadReleaseInfo() {
  const versionEl = document.getElementById('version-label');
  const androidBtn = document.getElementById('android-download');
  const windowsBtn = document.getElementById('windows-download');
  const webBtn = document.getElementById('web-open');
  const iosWebBtn = document.getElementById('ios-web');
  const androidNote = document.getElementById('android-note');
  const windowsNote = document.getElementById('windows-note');
  // Web app links are always on the buttons — not dependent on releases.json.
  applyWebButton(webBtn, null, WEB_APP_URL, WEB_APP_ALT_HOST);
  applyWebButton(iosWebBtn, null, WEB_APP_URL, null);

  try {
    const res = await fetch('releases.json', { cache: 'no-store' });
    if (!res.ok) throw new Error('Could not load release info');
    const text = await res.text();
    const data = JSON.parse(text.replace(/^\uFEFF/, ''));

    const versionText = `Version ${data.version} (build ${data.build})`;
    if (versionEl) versionEl.textContent = versionText;

    configureDownload(data.android, androidBtn, androidNote);
    configureDownload(data.windows, windowsBtn, windowsNote);

    const webUrl = data.web?.url || WEB_APP_URL;
    applyWebButton(webBtn, null, webUrl, null);
    applyWebButton(iosWebBtn, null, webUrl, null);
  } catch (_) {
    if (versionEl) versionEl.textContent = 'Release info unavailable';
    [androidBtn, windowsBtn].forEach((btn) => {
      if (btn) {
        btn.classList.add('is-disabled');
        btn.setAttribute('aria-disabled', 'true');
        btn.removeAttribute('href');
        btn.removeAttribute('download');
      }
    });
  }
}

function configureDownload(platform, button, noteEl) {
  if (!button) return;

  const available = platform?.available === true && platform?.file;
  if (available) {
    button.href = platform.file;
    button.setAttribute('download', '');
    button.classList.remove('is-disabled');
    button.removeAttribute('aria-disabled');
    if (noteEl && platform.size) {
      noteEl.textContent = `File size: ${platform.size}`;
    }
    return;
  }

  button.classList.add('is-disabled');
  button.setAttribute('aria-disabled', 'true');
  button.removeAttribute('href');
  button.removeAttribute('download');
  if (noteEl) {
    noteEl.textContent =
      'Installer not uploaded yet. Ask IT to run scripts/prepare-download-site.ps1 after building the app.';
  }
}

function initScrollReveal() {
  const items = document.querySelectorAll('.reveal');
  if (!items.length) return;

  if (!('IntersectionObserver' in window)) {
    items.forEach((el) => el.classList.add('is-visible'));
    return;
  }

  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          observer.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.12, rootMargin: '0px 0px -40px 0px' }
  );

  items.forEach((el) => observer.observe(el));
}

function markVersionReady() {
  const pill = document.getElementById('version-label');
  if (pill) pill.classList.add('is-ready');
}

document.addEventListener('DOMContentLoaded', () => {
  initScrollReveal();
  loadReleaseInfo().finally(markVersionReady);
});
