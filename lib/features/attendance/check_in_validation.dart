import 'package:geolocator/geolocator.dart';

import 'models/attendance_models.dart';

// Client-trusted time/GPS (same model as before). Queued check-ins re-validate
// using capture-time coordinates against the session center when syncing.

/// True if [t] falls within the session wall-clock window (inclusive start, inclusive end).
///
/// Offline check-ins validate using the **capture time** [t], not [DateTime.now],
/// so a queued row can be verified after the fact.
bool isTimestampWithinSessionBounds(AttendanceSession s, DateTime t) {
  if (t.isBefore(s.startTime)) return false;
  if (t.isAfter(s.endTime)) return false;
  return true;
}

/// True if [lat],[lng] is within [s.radiusMeters] of the session center.
bool isPositionWithinSession(AttendanceSession s, double lat, double lng) {
  if (s.remoteLearning) return true;
  final dist = Geolocator.distanceBetween(
    s.latitude,
    s.longitude,
    lat,
    lng,
  );
  return dist <= s.radiusMeters;
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
