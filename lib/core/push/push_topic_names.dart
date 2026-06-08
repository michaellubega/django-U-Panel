/// FCM topic names for notice pushes. Must stay in sync with Cloud Functions
/// ([functions/index.js]) that send to these topics.
const String kFcmAllNoticesTopic = 'all_notices';

/// Topics are restricted to `[a-zA-Z0-9-_.~%]+`; Firestore ids are usually safe,
/// but we sanitize so subscribe/send never fail on odd ids.
String sanitizeFcmTopicSegment(String raw) {
  return raw.replaceAll(RegExp(r'[^a-zA-Z0-9-_.~%]'), '_');
}

String fcmListNoticeTopic(String listId) =>
    'list_${sanitizeFcmTopicSegment(listId.trim())}';

/// Per-student notice pushes (missed session, etc.). Sync with [functions/index.js].
String fcmStudentNoticeTopic(String studentId) =>
    'stu_${sanitizeFcmTopicSegment(studentId.trim())}';

/// Per-lecturer notice pushes (take attendance reminders). Sync with [functions/index.js].
String fcmLecturerNoticeTopic(String lecturerUid) =>
    'lec_${sanitizeFcmTopicSegment(lecturerUid.trim())}';
