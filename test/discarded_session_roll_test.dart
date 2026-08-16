import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/features/attendance/models/attendance_models.dart';

void main() {
  setUp(() {
    AttendanceStore.lists.clear();
    AttendanceStore.sessions.clear();
    AttendanceStore.students.clear();
    AttendanceStore.signIns.clear();
    AttendanceStore.attendanceRecords.clear();
    AttendanceStore.invalidateLookupCaches();
  });

  AttendanceSession _session({required String id, bool rollDiscarded = false}) {
    return AttendanceSession(
      id: id,
      listId: 'list1',
      sessionCode: 'A12B',
      latitude: 0.3,
      longitude: 32.5,
      radiusMeters: 1500,
      startTime: DateTime(2026, 2, 1, 9),
      endTime: DateTime(2026, 2, 1, 10),
      status: SessionStatus.closed,
      createdBy: 'qa-1',
      rollDiscarded: rollDiscarded,
    );
  }

  test('discarded sessions are hidden from list history and roll stats', () {
    AttendanceStore.sessions.addAll([
      _session(id: 'kept'),
      _session(id: 'discarded', rollDiscarded: true),
    ]);

    final visible = AttendanceStore.sessionsForListNewestFirst('list1');
    expect(visible.map((s) => s.id).toList(), ['kept']);
    expect(_session(id: 'x', rollDiscarded: true).countsTowardRollStats, isFalse);
  });

  test('removeSession drops session and its attendance rows', () {
    AttendanceStore.sessions.add(_session(id: 'sess1'));
    AttendanceStore.attendanceRecords.add(
      AttendanceRecord(
        id: 'sess1_student1',
        sessionId: 'sess1',
        studentId: 'student1',
        course: 'CS101',
        timestamp: DateTime(2026, 2, 1, 9, 5),
        latitude: 0.3,
        longitude: 32.5,
        present: true,
      ),
    );

    AttendanceStore.removeSession('sess1');

    expect(AttendanceStore.sessionById('sess1'), isNull);
    expect(AttendanceStore.recordsForSession('sess1'), isEmpty);
  });
}
