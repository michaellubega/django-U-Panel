import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/core/push/push_topic_names.dart';
import 'package:u_panel/features/attendance/models/attendance_models.dart';

void main() {
  test('student sign-ins map to list notice tags used by session-start pushes', () {
    AttendanceStore.signIns.clear();
    AttendanceStore.signIns.add(
      SignInRecord(
        id: 'si-1',
        listId: 'list-abc',
        studentId: 'stu-42',
        course: 'Math',
        signedInAt: DateTime.utc(2026, 1, 1),
        registrationNumber: 'KIU1234S',
      ),
    );

    final tags = <String, String>{};
    for (final si in AttendanceStore.signIns) {
      final listId = si.listId.trim();
      if (listId.isNotEmpty) tags[pushListNoticeTag(listId)] = 'true';
      final sid = si.studentId.trim();
      if (sid.isNotEmpty) tags[pushStudentNoticeTag(sid)] = 'true';
    }

    expect(tags[pushListNoticeTag('list-abc')], 'true');
    expect(tags[pushStudentNoticeTag('stu-42')], 'true');
  });
}
