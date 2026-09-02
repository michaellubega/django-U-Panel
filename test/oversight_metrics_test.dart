import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/core/auth/user_role.dart';
import 'package:u_panel/features/attendance/models/attendance_models.dart';
import 'package:u_panel/features/oversight/oversight_metrics.dart';

void main() {
  setUp(() {
    AttendanceStore.lists.clear();
    AttendanceStore.sessions.clear();
    AttendanceStore.attendanceRecords.clear();
    AttendanceStore.signIns.clear();
    AttendanceStore.students.clear();
    AttendanceStore.invalidateLookupCaches();
  });

  test('UserRoleX.fromApi maps QAAT leadership roles', () {
    expect(UserRoleX.fromApi('vc')?.hasOversightReadAccess, isTrue);
    expect(UserRoleX.fromApi('dqa')?.label, 'Director of QA');
    expect(UserRoleX.fromApi('dean')?.hasStaffOperationalAccess, isFalse);
    expect(UserRole.qaStaff.hasStaffOperationalAccess, isTrue);
    expect(UserRole.admin.usesQaatOversightHome, isTrue);
  });

  test('OversightMetrics counts scheduled vs actual without writing data', () {
    final monday = DateTime(2024, 1, 1);
    AttendanceStore.lists.add(
      AttendanceList(
        id: 'list-1',
        time: '08:00',
        room: 'A1',
        whoTaught: 'Dr A',
        date: monday,
        program: AttendanceProgram.day,
        courses: const ['CS101'],
        year: '1',
        sem: '1',
        status: AttendanceListStatus.active,
      ),
    );
    AttendanceStore.lists.add(
      AttendanceList(
        id: 'list-2',
        time: '10:00',
        room: 'B2',
        whoTaught: 'Dr B',
        date: monday,
        program: AttendanceProgram.day,
        courses: const ['CS102'],
        year: '1',
        sem: '1',
        status: AttendanceListStatus.active,
      ),
    );
    AttendanceStore.sessions.add(
      AttendanceSession(
        id: 'sess-1',
        listId: 'list-1',
        sessionCode: 'A12B',
        latitude: 0,
        longitude: 0,
        radiusMeters: 1500,
        startTime: DateTime(2026, 9, 7, 8, 0), // Monday
        endTime: DateTime(2026, 9, 7, 10, 0),
        status: SessionStatus.active,
        createdBy: 'lec',
      ),
    );
    AttendanceStore.signIns.add(
      SignInRecord(
        id: 'si-1',
        listId: 'list-1',
        studentId: 'REG-1',
        course: 'CS101',
        signedInAt: DateTime(2026, 9, 1),
      ),
    );
    AttendanceStore.attendanceRecords.add(
      AttendanceRecord(
        id: 'rec-1',
        sessionId: 'sess-1',
        studentId: 'REG-1',
        course: 'CS101',
        timestamp: DateTime(2026, 9, 7, 8, 5),
        latitude: 0,
        longitude: 0,
        present: true,
      ),
    );

    AttendanceStore.invalidateLookupCaches();
    final snap = OversightMetrics.compute(now: DateTime(2026, 9, 7, 12));
    expect(snap.scheduledSessions, 2);
    expect(snap.actualSessions, 1);
    expect(snap.studentsPresent, 1);
    expect(snap.ghostLectureCount, 1);
    expect(snap.ghostSessions.first.unitName, contains('CS102'));
  });
}
