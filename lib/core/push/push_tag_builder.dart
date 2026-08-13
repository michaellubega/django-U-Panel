import '../auth/auth_repository.dart';
import '../auth/student_registration_number.dart';
import '../../features/attendance/attendance_list_hierarchy.dart';
import '../../features/attendance/models/attendance_models.dart';
import 'push_topic_names.dart';

/// OneSignal tags for the signed-in user. Must match server tag filters in
/// `backend/upanel/services/onesignal.py` and `notices/push_from_document.py`.
Map<String, String> buildPushTagsForUser(AuthRepository auth) {
  final tags = <String, String>{kPushAllNoticesTag: 'true'};

  final uid = auth.currentUserId?.trim();
  if (uid != null && uid.isNotEmpty) {
    if (auth.isLecturer) tags[pushLecturerNoticeTag(uid)] = 'true';
    if (auth.isKiuAdmin) tags[kPushKiuAdminsTag] = 'true';
  }

  final reg = auth.currentRegistrationNumber?.trim();
  if (reg != null && reg.isNotEmpty) {
    final normalizedReg = StudentRegistrationNumber.normalize(reg);
    final student = AttendanceStore.findStudentByReg(normalizedReg);
    if (student != null && student.id.trim().isNotEmpty) {
      tags[pushStudentNoticeTag(student.id)] = 'true';
    } else if (StudentRegistrationNumber.isCanonicalFormat(normalizedReg)) {
      tags[pushStudentNoticeTag(normalizedReg)] = 'true';
    }

    for (final listId
        in AttendanceStore.enrolledListIdsForRegistrationNormalized(reg)) {
      final id = listId.trim();
      if (id.isNotEmpty) tags[pushListNoticeTag(id)] = 'true';
    }
  }

  // Class-list / session-code notices target `list_{listId}` — students must
  // subscribe to every attendance list they have joined.
  for (final si in AttendanceStore.signIns) {
    final listId = si.listId.trim();
    if (listId.isNotEmpty) tags[pushListNoticeTag(listId)] = 'true';
    final sid = si.studentId.trim();
    if (sid.isNotEmpty) tags[pushStudentNoticeTag(sid)] = 'true';
  }

  for (final list in attendanceListsForCurrentStaff()) {
    final id = list.id.trim();
    if (id.isNotEmpty) tags[pushListNoticeTag(id)] = 'true';
  }

  return tags;
}
