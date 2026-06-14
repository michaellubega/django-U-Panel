import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/auth_repository.dart';
import '../../../core/cache/smart_cache_policy.dart';
import 'notices_disk_cache.dart';
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
    this.sessionId,
    this.targetLecturerUid,
    this.scheduledSlotAt,
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
  final String? sessionId;
  /// When [audience] targets a lecturer (`lecturerTakeAttendance`).
  final String? targetLecturerUid;
  /// Scheduled lesson slot this notice refers to (campus local time).
  final DateTime? scheduledSlotAt;
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
    } else if (audRaw == 'kiuadmins' || audRaw == 'kiu_admins') {
      audience = NoticeAudienceKind.kiuAdmins;
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
      sessionId: (data['sessionId'] as String?)?.trim(),
      targetLecturerUid: (data['targetLecturerUid'] as String?)?.trim(),
      scheduledSlotAt: (data['scheduledSlotAt'] as Timestamp?)?.toDate(),
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
    case NoticeAudienceKind.kiuAdmins:
      return 'kiuAdmins';
  }
}

/// When a notice becomes visible to recipients and eligible for push delivery.
DateTime noticeEffectiveAt(NoticeRecord n) => n.scheduledFor ?? n.createdAt;

/// True once [NoticeRecord.scheduledFor] has passed (or was never set).
bool noticeIsLive(NoticeRecord n, [DateTime? now]) {
  final at = now ?? DateTime.now();
  final sched = n.scheduledFor;
  return sched == null || !sched.isAfter(at);
}

/// Admins and list-owning lecturers may preview upcoming scheduled notices.
bool noticeAllowsPendingPreview({
  required NoticeRecord n,
  required bool admin,
  bool lecturer = false,
  Set<String> lecturerListIds = const {},
}) {
  if (admin) {
    if (n.audience == NoticeAudienceKind.kiuAdmins) {
      return (n.kind ?? '').toLowerCase() == 'manual';
    }
    return n.audience == NoticeAudienceKind.allAppUsers &&
        noticeNotifiesAdmin(n);
  }
  if (lecturer && n.audience == NoticeAudienceKind.classList) {
    final listId = n.targetListId?.trim() ?? '';
    return listId.isNotEmpty && lecturerListIds.contains(listId);
  }
  return false;
}

/// Session-code broadcasts are suppressed for remote-learning sessions.
bool isRemoteLearningSessionCodeNotice(NoticeRecord n) {
  if ((n.kind ?? '').toLowerCase() != 'sessioncode') return false;
  final sessionId = n.sessionId?.trim() ?? '';
  if (sessionId.isNotEmpty) {
    final sess = AttendanceStore.sessionById(sessionId);
    if (sess != null) return sess.remoteLearning;
  }
  final code = n.sessionCode?.trim() ?? '';
  if (code.isEmpty) return false;
  final normalized = normalizeSessionCodeInput(code);
  // Avoid scanning thousands of sessions on admin devices (OOM / UI jank).
  if (AttendanceStore.sessions.length > 300) return false;
  for (final s in AttendanceStore.sessions) {
    if (normalizeSessionCodeInput(s.sessionCode) == normalized) {
      return s.remoteLearning;
    }
  }
  return false;
}

/// QA / admin push + badge eligibility: broadcast notices only (not per-list).
bool noticeNotifiesAdmin(NoticeRecord n) {
  if (n.audience != NoticeAudienceKind.allAppUsers) return false;
  final k = (n.kind ?? '').toLowerCase();
  if (k == 'sessioncode' || k == 'missedsession') return false;
  if (k == 'lecturertakeattendance') return false;
  return true;
}

/// Whether [n] matches this user's audience (ignoring schedule).
bool noticeAudienceMatchesUser(
  NoticeRecord n, {
  required bool admin,
  bool kiuAdmin = false,
  bool lecturer = false,
  Set<String> lecturerListIds = const {},
  String? lecturerFirebaseUid,
  required String? studentId,
  required Set<String> signedListIds,
}) {
  final k = (n.kind ?? '').toLowerCase();
  if (n.audience == NoticeAudienceKind.kiuAdmins) {
    return kiuAdmin;
  }
  if (admin) {
    return noticeNotifiesAdmin(n);
  }
  if (lecturer) {
    final listId = n.targetListId?.trim() ?? '';
    if (k == 'lecturertakeattendance') {
      final target = n.targetLecturerUid?.trim() ?? '';
      final uid = lecturerFirebaseUid?.trim() ?? '';
      return target.isNotEmpty && uid.isNotEmpty && target == uid;
    }
    // Session codes and missed-lesson alerts are for students only.
    if (k == 'missedsession' || k == 'sessioncode') return false;
    if (k == 'qastartattendance') return false;
    if (n.audience == NoticeAudienceKind.allAppUsers) return true;
    if (n.audience == NoticeAudienceKind.classList) {
      return listId.isNotEmpty && lecturerListIds.contains(listId);
    }
    return false;
  }
  if (kiuAdmin) {
    if (k == 'lecturertakeattendance' || k == 'qastartattendance') {
      return false;
    }
    if (n.audience == NoticeAudienceKind.allAppUsers) return true;
    return false;
  }
  if (k == 'lecturertakeattendance' || k == 'qastartattendance') return false;
  if (n.audience == NoticeAudienceKind.allAppUsers) return true;
  if (n.audience == NoticeAudienceKind.student) {
    final tid = n.targetStudentId?.trim() ?? '';
    if (tid.isEmpty) return false;
    final sid = studentId?.trim() ?? '';
    return sid.isNotEmpty && tid == sid;
  }
  if (isRemoteLearningSessionCodeNotice(n)) return false;
  final listId = n.targetListId;
  if (listId == null || listId.isEmpty) return false;
  if (studentId == null || studentId.isEmpty) return false;
  return signedListIds.contains(listId);
}

/// Whether [n] should appear in the shell / notices list for this user.
bool noticeVisibleToUser(
  NoticeRecord n, {
  required bool admin,
  bool kiuAdmin = false,
  bool lecturer = false,
  Set<String> lecturerListIds = const {},
  String? lecturerFirebaseUid,
  required String? studentId,
  required Set<String> signedListIds,
}) {
  if (!noticeAudienceMatchesUser(
    n,
    admin: admin,
    kiuAdmin: kiuAdmin,
    lecturer: lecturer,
    lecturerListIds: lecturerListIds,
    lecturerFirebaseUid: lecturerFirebaseUid,
    studentId: studentId,
    signedListIds: signedListIds,
  )) {
    return false;
  }
  if (noticeIsLive(n)) return true;
  return noticeAllowsPendingPreview(
    n: n,
    admin: admin,
    lecturer: lecturer,
    lecturerListIds: lecturerListIds,
  );
}

/// Loads and publishes notices in `FirestoreCollections.notices`.
class NoticesRepository {
  NoticesRepository._();
  static final NoticesRepository instance = NoticesRepository._();

  final FirebaseFirestore _firestore = uPanelFirestore();

  Future<List<NoticeRecord>>? _fetchRecentInFlight;

  String _seenKeyForUser(String userKey) => '$_seenPrefix$userKey';

  /// Stable disk-cache partition per signed-in user (not shared across accounts).
  static String diskCacheUserKeyFrom({
    String? firebaseUid,
    String? registrationNumber,
  }) {
    final uid = firebaseUid?.trim();
    if (uid != null && uid.isNotEmpty) return uid;
    final reg = registrationNumber?.trim();
    if (reg != null && reg.isNotEmpty) return 'reg:${reg.toUpperCase()}';
    return 'anon';
  }

  String _diskCacheUserKey() => diskCacheUserKeyFrom(
        firebaseUid: AuthRepository.instance.currentFirebaseUid,
        registrationNumber: AuthRepository.instance.currentRegistrationNumber,
      );

  /// Clears cached notices for [userKey] and the legacy shared `all` bucket.
  static Future<void> clearDiskCacheForUserKey(String userKey) async {
    final key = userKey.trim();
    if (key.isNotEmpty) {
      await NoticesDiskCache.clear(key);
    }
    await NoticesDiskCache.clear('all');
  }

  /// Most recent first. Client-side filtering applies audience rules.
  ///
  /// Uses a 7-day disk cache; within TTL only notices newer than the cached
  /// newest row are requested from Firestore.
  Future<List<NoticeRecord>> fetchRecent({
    int limit = 100,
    bool force = false,
  }) {
    final inFlight = _fetchRecentInFlight;
    if (inFlight != null && !force) return inFlight;
    final task = _fetchRecentBody(limit: limit, force: force).whenComplete(() {
      _fetchRecentInFlight = null;
    });
    _fetchRecentInFlight = task;
    return task;
  }

  /// Cached rows for instant UI paint (ignores [force]).
  Future<List<NoticeRecord>> loadCachedRecent() async {
    final cached = await NoticesDiskCache.load(_diskCacheUserKey());
    return cached?.notices ?? const [];
  }

  DateTime? _newestCreatedAt(Iterable<NoticeRecord> notices) {
    DateTime? newest;
    for (final n in notices) {
      if (newest == null || n.createdAt.isAfter(newest)) {
        newest = n.createdAt;
      }
    }
    return newest;
  }

  List<NoticeRecord> _parseNoticeDocs(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final out = <NoticeRecord>[];
    final now = DateTime.now();
    for (final d in docs) {
      try {
        final r = NoticeRecord.fromDoc(d);
        if (r == null) continue;
        if (r.expiresAt != null && !r.expiresAt!.isAfter(now)) continue;
        out.add(r);
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('NoticesRepository: skip bad notice ${d.id}: $e');
          debugPrint('$st');
        }
      }
    }
    return out;
  }

  Future<List<NoticeRecord>> _fetchRecentBody({
    required int limit,
    required bool force,
  }) async {
    final cached = await NoticesDiskCache.load(_diskCacheUserKey());
    if (!force && cached != null) {
      final fresh = SmartCachePolicy.isWithinTtl(
        cached.cachedAt,
        SmartCachePolicy.profileAndNoticesTtl,
      );
      if (fresh) {
        final newest = _newestCreatedAt(cached.notices);
        if (newest == null) return cached.notices;
        try {
          final snap = await _firestore
              .collection(FirestoreCollections.notices)
              .where(
                'createdAt',
                isGreaterThan: Timestamp.fromDate(newest),
              )
              .orderBy('createdAt', descending: true)
              .limit(limit)
              .get();
          final incoming = _parseNoticeDocs(snap.docs);
          if (incoming.isEmpty) return cached.notices;
          final merged = NoticesDiskCache.mergeNotices(
            existing: cached.notices,
            incoming: incoming,
          );
          await NoticesDiskCache.save(
            userKey: _diskCacheUserKey(),
            notices: merged,
          );
          return merged;
        } catch (e, st) {
          if (kDebugMode) {
            debugPrint('NoticesRepository incremental fetch failed: $e');
            debugPrint('$st');
          }
          return cached.notices;
        }
      }
    }

    try {
      final snap = await _firestore
          .collection(FirestoreCollections.notices)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .get();
      final out = _parseNoticeDocs(snap.docs);
      await NoticesDiskCache.save(userKey: _diskCacheUserKey(), notices: out);
      return out;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('NoticesRepository.fetchRecent failed: $e');
        debugPrint('$st');
      }
      return cached?.notices ?? const [];
    }
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
    bool kiuAdmin = false,
    bool lecturer = false,
    Set<String> lecturerListIds = const {},
    String? lecturerFirebaseUid,
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
        kiuAdmin: kiuAdmin,
        lecturer: lecturer,
        lecturerListIds: lecturerListIds,
        lecturerFirebaseUid: lecturerFirebaseUid,
        studentId: studentId,
        signedListIds: signedListIds,
      )) {
        continue;
      }
      if (!noticeIsLive(n)) continue;
      if (seenAt == null || noticeEffectiveAt(n).isAfter(seenAt)) {
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

    if (auth.isQaStaff && !auth.isFullAdministrator) {
      const allowed = {
        NoticeAudienceKind.allAppUsers,
        NoticeAudienceKind.classList,
        NoticeAudienceKind.kiuAdmins,
      };
      if (!allowed.contains(draft.audience)) {
        return 'QA staff can only send to all users, a class list, or KIU administrators.';
      }
    }

    if (auth.isKiuAdmin && !auth.isAdmin) {
      const allowed = {
        NoticeAudienceKind.allAppUsers,
        NoticeAudienceKind.classList,
      };
      if (!allowed.contains(draft.audience)) {
        return 'KIU administrators can broadcast to all users or a class list.';
      }
    }

    final now = DateTime.now();
    if (draft.scheduledFor != null && !draft.scheduledFor!.isAfter(now)) {
      return 'Scheduled time must be in the future.';
    }
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
    if (session.remoteLearning) {
      return null;
    }
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
      await NoticesDiskCache.removeNotice(_diskCacheUserKey(), noticeId);
      return null;
    } catch (e) {
      return '$e';
    }
  }
}
