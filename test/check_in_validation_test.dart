import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/features/attendance/check_in_validation.dart';
import 'package:u_panel/features/attendance/models/attendance_models.dart';

AttendanceSession _session({
  required double radiusMeters,
  double centerLat = 0.3476,
  double centerLng = 32.5825,
}) {
  final start = DateTime.utc(2026, 3, 2, 8);
  return AttendanceSession(
    id: 'sess-1',
    listId: 'list-1',
    sessionCode: 'ABC123',
    latitude: centerLat,
    longitude: centerLng,
    radiusMeters: radiusMeters,
    startTime: start,
    endTime: start.add(const Duration(hours: 2)),
    status: SessionStatus.active,
    createdBy: 'Lecturer',
  );
}

void main() {
  test('locationMaxAgeForSession uses short window for on-campus sessions', () {
    final onCampus = _session(radiusMeters: 1500);
    expect(
      locationMaxAgeForSession(onCampus),
      checkInGeofenceLocationMaxAge,
    );

    final remote = AttendanceSession(
      id: 'sess-remote',
      listId: 'list-1',
      sessionCode: 'ABC123',
      latitude: 0,
      longitude: 0,
      radiusMeters: 0,
      startTime: DateTime.utc(2026, 3, 2, 8),
      endTime: DateTime.utc(2026, 3, 2, 10),
      status: SessionStatus.active,
      createdBy: 'Lecturer',
      remoteLearning: true,
    );
    expect(
      locationMaxAgeForSession(remote),
      checkInRemoteLocationMaxAge,
    );
  });

  test('1.5 km radius accepts nearby student coordinates', () {
    final session = _session(radiusMeters: 1500);
    const nearLat = 0.3476;
    const nearLng = 32.5830;
    expect(
      isPositionWithinSession(session, nearLat, nearLng),
      isTrue,
    );
    expect(
      verifyLinkedSessionCheckIn(
        session: session,
        at: session.startTime.add(const Duration(minutes: 5)),
        latitude: nearLat,
        longitude: nearLng,
      ).passed,
      isTrue,
    );
  });

  test('1.5 km radius rejects coordinates far from session center', () {
    final session = _session(radiusMeters: 1500);
    const farLat = 0.36;
    const farLng = 32.60;
    expect(
      isPositionWithinSession(session, farLat, farLng),
      isFalse,
    );
    final verification = verifyLinkedSessionCheckIn(
      session: session,
      at: session.startTime.add(const Duration(minutes: 5)),
      latitude: farLat,
      longitude: farLng,
    );
    expect(verification.passed, isFalse);
    expect(verification.failureMessage, contains('Too far from class'));
    expect(verification.failureMessage, contains('1.50 km'));
  });

  test('gps uncertainty buffer adds tolerance for inaccurate fixes', () {
    final session = _session(radiusMeters: 25);
    const nearLat = 0.34814;
    const nearLng = 32.5825;
    expect(
      isPositionWithinSession(session, nearLat, nearLng),
      isFalse,
    );
    expect(
      isPositionWithinSession(
        session,
        nearLat,
        nearLng,
        studentAccuracyMeters: 60,
      ),
      isTrue,
    );
  });
}
