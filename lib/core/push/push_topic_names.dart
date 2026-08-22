/// OneSignal tag names for notice pushes. Must stay in sync with
/// `backend/upanel/services/onesignal.py` and Celery notice tasks.
const String kPushAllNoticesTag = 'all_notices';

/// KIU administrator-only notice pushes.
const String kPushKiuAdminsTag = 'kiu_admins';

String sanitizePushTagSegment(String raw) {
  return raw.replaceAll(RegExp(r'[^a-zA-Z0-9-_.~%]'), '_');
}

String pushListNoticeTag(String listId) =>
    'list_${sanitizePushTagSegment(listId.trim())}';

String pushStudentNoticeTag(String studentId) =>
    'stu_${sanitizePushTagSegment(studentId.trim())}';

String pushLecturerNoticeTag(String userId) =>
    'lec_${sanitizePushTagSegment(userId.trim())}';

// Back-compat aliases for gradual rename at call sites.
const String kFcmAllNoticesTopic = kPushAllNoticesTag;
const String kFcmKiuAdminsTopic = kPushKiuAdminsTag;
String sanitizeFcmTopicSegment(String raw) => sanitizePushTagSegment(raw);
String fcmListNoticeTopic(String listId) => pushListNoticeTag(listId);
String fcmStudentNoticeTopic(String studentId) => pushStudentNoticeTag(studentId);
String fcmLecturerNoticeTopic(String uid) => pushLecturerNoticeTag(uid);
