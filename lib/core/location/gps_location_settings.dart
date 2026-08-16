import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:geolocator/geolocator.dart';

/// Platform-tuned GPS settings — improves reliability on web and iOS Safari.
LocationSettings buildGpsLocationSettings({
  required Duration timeLimit,
  bool highAccuracy = false,
  Duration webMaximumAge = Duration.zero,
}) {
  final accuracy = highAccuracy
      ? LocationAccuracy.best
      : LocationAccuracy.medium;

  if (kIsWeb) {
    return WebSettings(
      accuracy: accuracy,
      timeLimit: timeLimit,
      maximumAge: webMaximumAge,
    );
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return AppleSettings(
      accuracy: accuracy,
      pauseLocationUpdatesAutomatically: false,
      activityType: ActivityType.other,
      timeLimit: timeLimit,
    );
  }
  return LocationSettings(
    accuracy: highAccuracy ? LocationAccuracy.high : LocationAccuracy.medium,
    timeLimit: timeLimit,
  );
}

/// Longer read window for browsers and iOS where the first fix is often slow.
Duration gpsTimeLimitForPlatform({
  required Duration base,
  bool highAccuracy = false,
}) {
  if (!kIsWeb && defaultTargetPlatform != TargetPlatform.iOS) {
    return base;
  }
  final extra = highAccuracy ? 6 : 4;
  return base + Duration(seconds: extra);
}
