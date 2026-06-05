import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:geolocator/geolocator.dart';

import '../connectivity/app_connectivity.dart';

String _webLocationDeniedForeverMessage() {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return 'Safari has location blocked for this site. Use the https address '
        '(e.g. your …web.app link). Tap the aA icon left of the address bar → '
        'Website Settings → Location → Allow. If you tapped Don’t Allow before, '
        'you must change it there—HTTPS alone does not turn location on.';
  }
  return 'Location is blocked for this site in your browser. Open an https:// '
      'URL, tap the lock or site icon in the address bar, open Site settings, '
      'set Location to Allow, refresh, and try again.';
}

String _webLocationDeniedMessage() {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return 'Location was denied. Tap the aA icon left of the address bar → '
        'Website Settings → Location → Allow, or tap Allow if Safari asks again.';
  }
  return 'Location was denied. Tap the lock or site icon in the address bar, '
      'allow location for this site, and try again (https required).';
}

/// Ensures location services are on and the app has location permission.
/// Returns `null` if GPS may be read; otherwise a short message for the user.
///
/// On web, the browser’s Geolocation API is used (HTTPS or localhost required).
Future<String?> ensureLocationReady() async {
  if (!kIsWeb) {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return 'Location is turned off. Enable location (GPS) in your phone settings, then try again.';
    }
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.unableToDetermine) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied) {
    if (kIsWeb) {
      return _webLocationDeniedMessage();
    }
    return 'Location permission was denied. Allow location when prompted, or turn it on in app settings.';
  }
  if (permission == LocationPermission.deniedForever) {
    if (kIsWeb) {
      return _webLocationDeniedForeverMessage();
    }
    return 'Location is blocked for this app. Open Settings → Apps → U-Panel → Permissions → Location and allow.';
  }
  return null;
}

/// Last-known fix accepted when starting a session without waiting for GPS.
const Duration kSessionStartLastKnownMaxAgeOnline = Duration(hours: 4);
const Duration kSessionStartLastKnownMaxAgeOffline = Duration(days: 1);

/// Fast path for [StartSessionScreen]: last-known fix only (no [getCurrentPosition]).
Future<Position?> quickPositionForSessionStart() async {
  final ready = await ensureLocationReady();
  if (ready != null) return null;
  try {
    final last = await Geolocator.getLastKnownPosition();
    if (last == null) return null;
    final maxAge = AppConnectivity.instance.isOnline
        ? kSessionStartLastKnownMaxAgeOnline
        : kSessionStartLastKnownMaxAgeOffline;
    if (DateTime.now().difference(last.timestamp) <= maxAge) {
      return last;
    }
  } catch (_) {}
  return null;
}

/// Tries a fresh GPS fix.
Future<({Position? position, String? errorMessage})> tryAcquireGpsPosition({
  Duration timeLimit = const Duration(seconds: 30),
}) async {
  final ready = await ensureLocationReady();
  if (ready != null) {
    return (position: null, errorMessage: ready);
  }
  try {
    final p = await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: timeLimit,
      ),
    );
    return (position: p, errorMessage: null);
  } on TimeoutException catch (_) {
    final lastKnown = await Geolocator.getLastKnownPosition();
    if (lastKnown != null) {
      return (position: lastKnown, errorMessage: null);
    }
    return (
      position: null,
      errorMessage:
          'GPS timed out. Move to an open area or wait for a fix, then tap again.',
    );
  } catch (_) {
    final lastKnown = await Geolocator.getLastKnownPosition();
    if (lastKnown != null) {
      return (position: lastKnown, errorMessage: null);
    }
    return (
      position: null,
      errorMessage: kIsWeb
          ? (defaultTargetPlatform == TargetPlatform.iOS
              ? 'Could not read your location. In Safari use the aA menu → '
                  'Website Settings → Location → Allow, then try again on https.'
              : 'Could not read your location. Allow location for this site in '
                  'the address bar and use an https:// or localhost URL.')
          : 'Could not read GPS. Check that location permission is allowed and GPS is on.',
    );
  }
}
