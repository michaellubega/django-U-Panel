import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/auth_repository.dart';
import '../../../core/firebase/firestore_collections.dart';
import '../../../core/firebase/u_panel_firestore.dart';
import '../../attendance/attendance_list_hierarchy.dart';
import '../../attendance/models/attendance_models.dart';
import '../create_notice_screen.dart';

const String _seenPrefix = 'notices_last_seen_ms_v1_';

/// One notice row from Firestore.
class NoticeRecord {
  const NoticeRecord({
    required this.id,
    required this.title,
    required this.body,
    required this.author,
    required this.createdAt,
    this.scheduledFor,
    this.sendPush = false,
    required this.audience,
    this.targetListId,
    this.targetListTitle,
    this.targetStudentId,
    this.sessionCode,
    this.kind,
    this.expiresAt,
  });

  final String id;
  final String title;
  final String body;
  final String author;
  final DateTime createdAt;
  final DateTime? scheduledFor;
  final bool sendPush;
  final NoticeAudienceKind audience;
  final String? targetListId;
  final String? targetListTitle;
  /// When [audience] is [NoticeAudienceKind.student], roster student Firestore id.
  final String? targetStudentId;
  final String? sessionCode;
  final String? kind;
  final DateTime? expiresAt;

  static NoticeRecord? fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data();
    if (data == null) return null;
    final title = (data['title'] as String?)?.trim() ?? '';
    final body = (data['body'] as String?)?.trim() ?? '';
    if (title.isEmpty && body.isEmpty) return null;
    final created = (data['createdAt'] as Timestamp?)?.toDate();
    if (created == null) return null;
    final sched = (data['scheduledFor'] as Timestamp?)?.toDate();
    final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
    final audRaw = (data['audience'] as String?)?.trim().toLowerCase();
    final NoticeAudienceKind audience;
    if (audRaw == 'classlist' || audRaw == 'class_list') {
      audience = NoticeAudienceKind.classList;
    } else if (audRaw == 'student' || audRaw == 'targetstudent') {
      audience = NoticeAudienceKind.student;
    } else {
      audience = NoticeAudienceKind.allAppUsers;
    }
    return NoticeRecord(
      id: d.id,
      title: title,
      body: body,
      author: (data['author'] as String?)?.trim() ?? 'Admin',
      createdAt: created,
      scheduledFor: sched,
      sendPush: data['sendPush'] as bool? ?? false,
      audience: audience,
      targetListId: (data['targetListId'] as String?)?.trim(),
      targetListTitle: (data['targetListTitle'] as String?)?.trim(),
      targetStudentId: (data['targetStudentId'] as String?)?.trim(),
      sessionCode: (data['sessionCode'] as String?)?.trim(),
      kind: (data['kind'] as String?)?.trim(),
      expiresAt: expiresAt,
    );
  }
}

String _audienceToField(NoticeAudienceKind k) {
  switch (k) {
    case NoticeAudienceKind.classList:
      return 'classList';
    case NoticeAudienceKind.student:
      return 'student';
    case NoticeAudienceKind.allAppUsers:
      return 'allAppUsers';
  }
}

/// Whether [n] should appear in the shell / notices list for this user.
bool noticeVisibleToUser(
  NoticeRecord n, {
  required bool admin,
  bool lecturer = false,
  Set<String> lecturerListIds = const {},
  required String? studentId,
  required Set<String> signedListIds,
}) {
  if (admin) {
    // Session / absence notices are for students only.
    final k = (n.kind ?? '').toLowerCase();
    if (k == 'sessioncode' || k == 'missedsession') return false;
    return true;
  }
  if (lecturer) {
    final k = (n.kind ?? '').toLowerCase();
    final listId = n.targetListId?.trim() ?? '';
    // Session codes and missed-lesson alerts are for students only.
    if (k == 'missedsession' || k == 'sessioncode') return false;
    if (n.audience == NoticeAudienceKind.allAppUsers) return true;
    if (n.audience == NoticeAudienceKind.classList) {
      return listId.isNotEmpty && lecturerListIds.contains(listId);
    }
    return false;
  }
  if (n.audience == NoticeAudienceKind.allAppUsers) return true;
  if (n.audience == NoticeAudienceKind.student) {
    final tid = n.targetStudentId?.trim() ?? '';
    if (tid.isEmpty) return false;
    final sid = studentId?.trim() ?? '';
    return sid.isNotEmpty && tid == sid;
  }
  final listId = n.targetListId;
  if (listId == null || listId.isEmpty) return false;
  if (studentId == null || studentId.isEmpty) return false;
  return signedListIds.contains(listId);
}

/// Loads and publishes notices in `FirestoreCollections.notices`.
class NoticesRepository {
  NoticesRepository._();
  static final NoticesRepository instance = NoticesRepository._();

  final FirebaseFirestore _firestore = uPanelFirestore();

  String _seenKeyForUser(String userKey) => '$_seenPrefix$userKey';

  /// Most recent first. Client-side filtering applies audience rules.
  Future<List<NoticeRecord>> fetchRecent({int limit = 100}) async {
    final snap = await _firestore
        .collection(FirestoreCollections.notices)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get();
    final out = <NoticeRecord>[];
    final now = DateTime.now();
    for (final d in snap.docs) {
      final r = NoticeRecord.fromDoc(d);
      if (r == null) continue;
      if (r.expiresAt != null && !r.expiresAt!.isAfter(now)) continue;
      out.add(r);
    }
    return out;
  }

  Future<DateTime?> getLastSeenAt(String userKey) async {
    final p = await SharedPreferences.getInstance();
    final ms = p.getInt(_seenKeyForUser(userKey));
    if (ms == null || ms <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> markSeenAt(String userKey, DateTime at) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_seenKeyForUser(userKey), at.millisecondsSinceEpoch);
  }

  Future<int> unseenCountForUser({
    required String userKey,
    required bool admin,
    bool lecturer = false,
    Set<String> lecturerListIds = const {},
    required String? studentId,
    required Set<String> signedListIds,
    int limit = 100,
  }) async {
    final seenAt = await getLastSeenAt(userKey);
    final notices = await fetchRecent(limit: limit);
    var c = 0;
    for (final n in notices) {
      if (!noticeVisibleToUser(
        n,
        admin: admin,
        lecturer: lecturer,
        lecturerListIds: lecturerListIds,
        studentId: studentId,
        signedListIds: signedListIds,
      )) {
        continue;
      }
      if (seenAt == null || n.createdAt.isAfter(seenAt)) {
        c++;
      }
    }
    return c;
  }

  /// Returns null on success, otherwise an error message.
  Future<String?> publish({
    required NoticeCreationResult draft,
    required String author,
  }) async {
    final auth = AuthRepository.instance;
    final isLecturer =
        auth.lecturerCheckDone && auth.isLecturer && !auth.isAdmin;
    if (isLecturer) {
      if (draft.audience != NoticeAudienceKind.classList) {
        return 'Lecturers can only send notices to a class list.';
      }
      final listId = draft.targetListId?.trim() ?? '';
      if (listId.isEmpty) {
        return 'Choose a class list for this notice.';
      }
      final uid = auth.currentFirebaseUid?.trim() ?? '';
      if (uid.isEmpty) {
        return 'You must be signed in to publish a notice.';
      }
      final list = AttendanceStore.listById(listId);
      if (list == null ||
          !attendanceListAccessibleToLecturer(list, uid)) {
        return 'You can only notify class lists assigned to you or that you created.';
      }
    }

    final now = DateTime.now();
    final map = <String, dynamic>{
      'title': draft.title.trim(),
      'body': draft.body.trim(),
      'author': author.trim().isEmpty
          ? (isLecturer ? 'Lecturer' : 'Admin')
          : author.trim(),
      'createdAt': FieldValue.serverTimestamp(),
      'sendPush': draft.sendPush,
      'audience': _audienceToField(draft.audience),
      'kind': 'manual',
    };
    if (draft.validFor != null) {
      final base = (draft.scheduledFor != null && draft.scheduledFor!.isAfter(now))
          ? draft.scheduledFor!
          : now;
      map['expiresAt'] = Timestamp.fromDate(base.add(draft.validFor!));
    }
    if (draft.scheduledFor != null) {
      map['scheduledFor'] = Timestamp.fromDate(draft.scheduledFor!);
    }
    if (draft.audience == NoticeAudienceKind.classList) {
      map['targetListId'] = draft.targetListId ?? '';
      map['targetListTitle'] = draft.targetListTitle ?? '';
    }
    try {
      await _firestore.collection(FirestoreCollections.notices).add(map);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Returns null on success, otherwise an error message.
  Future<String?> publishSessionStartNotice({
    required AttendanceList list,
    required AttendanceSession session,
    required String createdBy,
  }) async {
    final code = normalizeSessionCodeInput(session.sessionCode);
    final map = <String, dynamic>{
      'title': list.displayTitle,
      'body': '',
      'author': createdBy.trim().isEmpty ? 'QA' : createdBy.trim(),
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(
        DateTime.now().add(const Duration(hours: 3)),
      ),
      'sendPush': true,
      'audience': 'classList',
      'targetListId': list.id,
      'targetListTitle': list.displayTitle,
      'sessionCode': code,
      'kind': 'sessionCode',
      'sessionId': session.id,
    };
    try {
      await _firestore.collection(FirestoreCollections.notices).add(map);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Returns null on success, otherwise an error message.
  Future<String?> deleteNotice(String noticeId) async {
    try {
      await _firestore.collection(FirestoreCollections.notices).doc(noticeId).delete();
      return null;
    } catch (e) {
      return '$e';
    }
  }
}
