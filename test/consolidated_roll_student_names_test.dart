import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/features/attendance/models/attendance_models.dart';

void main() {
  setUp(() {
    AttendanceStore.lists.clear();
    AttendanceStore.sessions.clear();
    AttendanceStore.students.clear();
    AttendanceStore.signIns.clear();
    AttendanceStore.attendanceRecords.clear();
    AttendanceStore.clearServerPendingCheckIns();
    AttendanceStore.invalidateLookupCaches();
  });

  group('AttendanceStore.resolveStudentForRoll', () {
    test('maps firebase uid roll row to student stored by registration id', () {
      AttendanceStore.students.add(
        StudentRecord(
          id: 'KIU1234S',
          name: 'Jane Doe',
          registrationNumber: 'KIU1234S',
          threeDigitCode: '123',
          initials: 'JD',
        ),
      );
      AttendanceStore.signIns.add(
        SignInRecord(
          id: 'si1',
          listId: 'list1',
          studentId: 'firebase-uid-abc',
          course: 'CS101',
          signedInAt: DateTime(2026, 1, 10),
          registrationNumber: 'KIU1234S',
        ),
      );

      final resolved = AttendanceStore.resolveStudentForRoll(
        'firebase-uid-abc',
        listId: 'list1',
      );

      expect(resolved?.name, 'Jane Doe');
      expect(resolved?.registrationNumber, 'KIU1234S');
    });

    test('roster map includes attendance-only students with known registration', () {
      AttendanceStore.students.add(
        StudentRecord(
          id: 'KIU5678S',
          name: 'John Smith',
          registrationNumber: 'KIU5678S',
          threeDigitCode: '456',
          initials: 'JS',
        ),
      );
      AttendanceStore.sessions.add(
        AttendanceSession(
          id: 'sess1',
          listId: 'list1',
          sessionCode: 'ABC123',
          latitude: 0.3,
          longitude: 32.5,
          radiusMeters: 50,
          startTime: DateTime(2026, 2, 1, 9),
          endTime: DateTime(2026, 2, 1, 11),
          status: SessionStatus.active,
          createdBy: 'lecturer-1',
        ),
      );
      AttendanceStore.attendanceRecords.add(
        AttendanceRecord(
          id: 'sess1_uid-xyz',
          sessionId: 'sess1',
          studentId: 'uid-xyz',
          course: 'CS101',
          timestamp: DateTime(2026, 2, 1, 9, 5),
          latitude: 0.3,
          longitude: 32.5,
        ),
      );
      AttendanceStore.signIns.add(
        SignInRecord(
          id: 'si2',
          listId: 'list1',
          studentId: 'uid-xyz',
          course: 'CS101',
          signedInAt: DateTime(2026, 2, 1, 8, 50),
          registrationNumber: 'KIU5678S',
        ),
      );

      final map = AttendanceStore.rosterStudentMapForList('list1');

      expect(map['uid-xyz']?.name, 'John Smith');
    });
  });
}
