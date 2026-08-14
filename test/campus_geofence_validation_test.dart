import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/features/attendance/check_in_validation.dart';
import 'package:u_panel/features/attendance/models/attendance_models.dart';
import 'package:u_panel/features/campus_presence/campus_geofence_validation.dart';
import 'package:u_panel/features/campus_presence/models/campus_presence_models.dart';

void main() {
  test('sessionRequiresHighAccuracyGps for tight radii only', () {
    final tight = AttendanceSession(
      id: 's1',
      listId: 'l1',
      sessionCode: 'ABC123',
      latitude: 0.34,
      longitude: 32.58,
      radiusMeters: 50,
      startTime: DateTime.utc(2026, 3, 2, 8),
      endTime: DateTime.utc(2026, 3, 2, 10),
      status: SessionStatus.active,
      createdBy: 'lec',
    );
    final wide = AttendanceSession(
      id: 's2',
      listId: 'l1',
      sessionCode: 'ABC124',
      latitude: 0.34,
      longitude: 32.58,
      radiusMeters: 1500,
      startTime: DateTime.utc(2026, 3, 2, 8),
      endTime: DateTime.utc(2026, 3, 2, 10),
      status: SessionStatus.active,
      createdBy: 'lec',
    );
    expect(sessionRequiresHighAccuracyGps(tight), isTrue);
    expect(sessionRequiresHighAccuracyGps(wide), isFalse);
  });

  test('campus geofence applies GPS tolerance buffer', () {
    const fence = CampusGeofence(
      latitude: 0.3476,
      longitude: 32.5825,
      radiusMeters: 1500,
      label: 'Main campus',
    );
    expect(
      isPositionWithinCampus(fence, fence.latitude, fence.longitude),
      isTrue,
    );
    // ~1510 m east — outside raw 1500 m radius but inside +25 m buffer.
    expect(
      isPositionWithinCampus(fence, 0.3476, 32.59615),
      isTrue,
    );
    expect(kCampusGeofenceBufferMeters, 25);
  });
}
