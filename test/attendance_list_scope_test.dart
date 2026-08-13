import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/features/attendance/attendance_list_hierarchy.dart';
import 'package:u_panel/features/attendance/models/attendance_models.dart';

AttendanceList _sampleList(String id) => AttendanceList(
      id: id,
      time: '08:00',
      room: 'R1',
      whoTaught: 'Dr. Test',
      date: DateTime(2026, 3, 2),
      courses: const ['CS101'],
      year: '1',
      sem: '1',
    );

void main() {
  tearDown(() {
    AttendanceStore.lists.clear();
    AttendanceStore.invalidateLookupCaches();
  });

  test('scoped list source drops lists removed from the live store', () {
    final kept = _sampleList('keep');
    final removed = _sampleList('gone');
    AttendanceStore.lists.addAll([kept, removed]);

    final scopedSnapshot = [kept, removed];
    AttendanceStore.removeList('gone');

    final resolved = attendanceListsFromOptionalScope(scopedSnapshot);
    expect(resolved.map((l) => l.id), ['keep']);
  });

  test('null scope uses staff list helper path', () {
    AttendanceStore.lists.add(_sampleList('a'));
    expect(
      attendanceListsFromOptionalScope(null),
      isEmpty,
    );
  });
}
