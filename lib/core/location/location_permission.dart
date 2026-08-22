import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:geolocator/geolocator.dart';

import 'gps_location_settings.dart';

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

/// Whether device-level location services (GPS) are enabled.
Future<bool> isDeviceLocationServiceEnabled() async {
  if (kIsWeb) return true;
  return Geolocator.isLocationServiceEnabled();
}

Future<void> openDeviceLocationSettings() async {
  if (kIsWeb) return;
  await Geolocator.openLocationSettings();
}

Future<void> openAppPermissionSettings() async {
  await Geolocator.openAppSettings();
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

/// Result of a GPS read attempt.
class GpsAcquireResult {
  const GpsAcquireResult({
    this.position,
    this.errorMessage,
    this.locationServiceDisabled = false,
    this.permissionBlocked = false,
  });

  final Position? position;
  final String? errorMessage;
  final bool locationServiceDisabled;
  final bool permissionBlocked;
}

/// Reuse a cached or OS last-known fix when it is newer than this (sign-in).
const Duration recentLocationMaxAge = Duration(minutes: 5);

Position? _memoryCachedPosition;
DateTime? _memoryCachedAt;

bool positionCapturedWithin(Position position, Duration maxAge) {
  final captured = position.timestamp;
  return DateTime.now().difference(captured) <= maxAge;
}

void rememberGpsPosition(Position position) {
  _memoryCachedPosition = position;
  _memoryCachedAt = DateTime.now();
}

/// In-memory cache from this app session, then OS last-known, when ≤ [recentLocationMaxAge].
Future<Position?> readRecentKnownPosition({
  Duration maxAge = recentLocationMaxAge,
}) async {
  final cached = _memoryCachedPosition;
  final cachedAt = _memoryCachedAt;
  if (cached != null &&
      cachedAt != null &&
      DateTime.now().difference(cachedAt) <= maxAge) {
    return cached;
  }
  try {
    final last = await Geolocator.getLastKnownPosition();
    if (last != null && positionCapturedWithin(last, maxAge)) {
      rememberGpsPosition(last);
      return last;
    }
  } catch (_) {}
  return null;
}

/// Reads GPS for check-in: reuses last-known fix when ≤ [reuseMaxAge] old unless
/// [forceFresh] is true. Use [highAccuracy] for tight class geofences (≤ 100 m).
Future<GpsAcquireResult> acquireCurrentGpsPosition({
  Duration timeLimit = const Duration(seconds: 30),
  Duration reuseMaxAge = recentLocationMaxAge,
  bool forceFresh = false,
  bool highAccuracy = false,
}) async {
  if (!kIsWeb) {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return const GpsAcquireResult(
        locationServiceDisabled: true,
        errorMessage:
            'Location is turned off. Turn on GPS, then tap Get current location.',
      );
    }
  }

  final ready = await ensureLocationReady();
  if (ready != null) {
    final blocked = ready.contains('blocked') ||
        ready.contains('denied') ||
        ready.contains('Don’t Allow');
    return GpsAcquireResult(
      errorMessage: ready,
      permissionBlocked: blocked,
    );
  }

  if (!forceFresh) {
    final recent = await readRecentKnownPosition(maxAge: reuseMaxAge);
    if (recent != null) {
      return GpsAcquireResult(position: recent);
    }
  }

  final effectiveLimit = gpsTimeLimitForPlatform(
    base: timeLimit,
    highAccuracy: highAccuracy,
  );
  final webMaxAge = forceFresh ? Duration.zero : reuseMaxAge;

  Future<GpsAcquireResult> readOnce({bool retry = false}) async {
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: buildGpsLocationSettings(
          timeLimit: effectiveLimit + (retry ? const Duration(seconds: 4) : Duration.zero),
          highAccuracy: highAccuracy || retry,
          webMaximumAge: webMaxAge,
        ),
      );
      rememberGpsPosition(p);
      return GpsAcquireResult(position: p);
    } on TimeoutException catch (_) {
      if (!retry && (kIsWeb || defaultTargetPlatform == TargetPlatform.iOS)) {
        return readOnce(retry: true);
      }
      return const GpsAcquireResult(
        errorMessage:
            'GPS timed out. Move to an open area, keep location on, then try again.',
      );
    } catch (_) {
      if (!retry && (kIsWeb || defaultTargetPlatform == TargetPlatform.iOS)) {
        return readOnce(retry: true);
      }
      return GpsAcquireResult(
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

  return readOnce();
}

/// Legacy wrapper — prefer [acquireCurrentGpsPosition].
Future<({Position? position, String? errorMessage})> tryAcquireGpsPosition({
  Duration timeLimit = const Duration(seconds: 30),
}) async {
  final r = await acquireCurrentGpsPosition(timeLimit: timeLimit);
  return (position: r.position, errorMessage: r.errorMessage);
}
