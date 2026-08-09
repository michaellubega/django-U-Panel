import 'package:geolocator/geolocator.dart';

import 'models/attendance_models.dart';

/// Matches server-side buffer in `documents/services/check_in.py`.
const double kCheckInGeofenceBufferMeters = 15;

// Client-trusted time/GPS (same model as before). Queued check-ins re-validate
// using capture-time coordinates against the session center when syncing.

/// True if [t] falls within the session wall-clock window (inclusive start, inclusive end).
///
/// Offline check-ins validate using the **capture time** [t], not [DateTime.now],
/// so a queued row can be verified after the fact.
bool isTimestampWithinSessionBounds(AttendanceSession s, DateTime t) {
  if (t.isBefore(s.startTime)) return false;
  if (t.isAfter(s.endTime) && !s.isOpenForCheckIn) return false;
  return true;
}

/// Human-readable distance (meters under 1 km, otherwise km).
String formatDistanceMeters(double meters) {
  if (!meters.isFinite || meters < 0) return '—';
  if (meters >= 1000) {
    final km = meters / 1000;
    return km >= 10
        ? '${km.toStringAsFixed(1)} km'
        : '${km.toStringAsFixed(2)} km';
  }
  return '${meters.round()} m';
}

/// Human-readable allowed radius for session UI / errors.
String formatSessionRadiusMeters(double radiusMeters) {
  if (!radiusMeters.isFinite || radiusMeters <= 0) return '—';
  return formatDistanceMeters(radiusMeters);
}

bool isValidCheckInCoordinates(double lat, double lng) {
  if (!lat.isFinite || !lng.isFinite) return false;
  // Null Island / unset GPS placeholders must not pass geofence checks.
  if (lat.abs() < 0.001 && lng.abs() < 0.001) return false;
  return true;
}

/// On-campus sessions need a real centre and positive radius.
bool isSessionGeofenceConfigured(AttendanceSession s) {
  if (s.remoteLearning) return true;
  if (s.locationMetadataPending) return false;
  if (s.radiusMeters <= 0) return false;
  return isValidCheckInCoordinates(s.latitude, s.longitude);
}

/// Long-distance learning, pending lecturer GPS, or location not set — skip radius.
bool sessionSkipsLocationCheck(AttendanceSession s) {
  return s.remoteLearning ||
      s.locationMetadataPending ||
      !isSessionGeofenceConfigured(s);
}

/// Pending queue replay: strict geofence or correction path (server uses same rules).
bool pendingReplayLocationOk(
  AttendanceSession session,
  double latitude,
  double longitude,
) {
  if (sessionSkipsLocationCheck(session)) return true;
  if (!isValidCheckInCoordinates(latitude, longitude)) return false;
  return isPositionWithinSession(session, latitude, longitude) ||
      positionQualifiesForPresentCorrection(session, latitude, longitude);
}

/// Haversine distance from the session centre to a student fix (metres).
double sessionDistanceMeters(AttendanceSession s, double lat, double lng) {
  return Geolocator.distanceBetween(
    s.latitude,
    s.longitude,
    lat,
    lng,
  );
}

/// True if [lat],[lng] is within [s.radiusMeters] of the session center.
bool isPositionWithinSession(AttendanceSession s, double lat, double lng) {
  if (sessionSkipsLocationCheck(s)) return true;
  if (!isValidCheckInCoordinates(lat, lng)) return false;
  final dist = sessionDistanceMeters(s, lat, lng);
  return dist <= s.radiusMeters + kCheckInGeofenceBufferMeters;
}

/// Relaxed GPS match when upgrading an official absent row from device evidence.
bool positionQualifiesForPresentCorrection(
  AttendanceSession s,
  double lat,
  double lng,
) {
  if (isPositionWithinSession(s, lat, lng)) return true;
  if (!isValidCheckInCoordinates(lat, lng)) return false;
  if (s.remoteLearning) return true;
  if (!isSessionGeofenceConfigured(s)) return true;
  return false;
}

/// Result of verifying time + GPS against linked [AttendanceSession] metadata.
class LinkedSessionCheckInVerification {
  const LinkedSessionCheckInVerification({
    required this.passed,
    this.timeOk = false,
    this.locationOk = false,
    this.failureMessage,
  });

  final bool passed;
  final bool timeOk;
  final bool locationOk;
  final String? failureMessage;
}

/// Fast local check once a code has linked to [session] metadata.
LinkedSessionCheckInVerification verifyLinkedSessionCheckIn({
  required AttendanceSession session,
  required DateTime at,
  required double latitude,
  required double longitude,
}) {
  final timeOk = isTimestampWithinSessionBounds(session, at);
  if (!timeOk) {
    return const LinkedSessionCheckInVerification(
      passed: false,
      failureMessage:
          'Check-in is only allowed during the scheduled session window.',
    );
  }
  if (sessionSkipsLocationCheck(session)) {
    return const LinkedSessionCheckInVerification(
      passed: true,
      timeOk: true,
      locationOk: true,
    );
  }
  final locationOk =
      isPositionWithinSession(session, latitude, longitude);
  if (!locationOk) {
    return LinkedSessionCheckInVerification(
      passed: false,
      timeOk: true,
      locationOk: false,
      failureMessage:
          sessionGeofenceFailureMessage(session, latitude, longitude),
    );
  }
  return const LinkedSessionCheckInVerification(
    passed: true,
    timeOk: true,
    locationOk: true,
  );
}

/// User-facing message when a live check-in fails the geofence.
String sessionGeofenceFailureMessage(
  AttendanceSession s,
  double lat,
  double lng,
) {
  if (sessionSkipsLocationCheck(s)) {
    return 'Location is not required for this session.';
  }
  if (!isValidCheckInCoordinates(lat, lng)) {
    return 'Could not read a valid GPS location. Turn on location and try again.';
  }
  final dist = sessionDistanceMeters(s, lat, lng);
  return 'Too far from class (${formatDistanceMeters(dist)} away). '
      'You must be within ${formatSessionRadiusMeters(s.radiusMeters)} of the '
      'session location.';
}

/// Course for a present row: roster sign-in course, else first list course, else em dash.
String resolveCourseForStudentCheckIn(AttendanceList list, String studentId) {
  var c = AttendanceStore.courseForStudentOnList(list.id, studentId);
  if (c.isEmpty && list.coursesSafe.isNotEmpty) {
    c = list.coursesSafe.first;
  }
  if (c.isEmpty) {
    c = '—';
  }
  return c;
}
