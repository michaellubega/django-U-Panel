/* eslint-disable no-undef */
// Must stay in sync with `web/index.html` Firebase JS version (compat API).
importScripts('https://www.gstatic.com/firebasejs/11.3.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/11.3.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyAUiWcvr6UyCVjv3OlQNxtFlEnfpRA4wGE',
  appId: '1:307189985628:web:0244a8c9bc9d4fed0c9199',
  messagingSenderId: '307189985628',
  projectId: 'u-panel-2026',
  authDomain: 'u-panel-2026.firebaseapp.com',
  storageBucket: 'u-panel-2026.firebasestorage.app',
});

const messaging = firebase.messaging();

messaging.onBackgroundMessage((payload) => {
  const title =
    (payload.notification && payload.notification.title) ||
    (payload.data && payload.data.title) ||
    'U-Panel';
  const body =
    (payload.notification && payload.notification.body) ||
    (payload.data && payload.data.body) ||
    '';
  return self.registration.showNotification(title, {
    body,
    icon: '/icons/Icon-192.png',
    tag: payload.messageId || 'upanel-bg',
  });
});
