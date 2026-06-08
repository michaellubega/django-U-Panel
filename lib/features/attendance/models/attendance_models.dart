import 'dart:math';

import '../data/pending_retention.dart';

/// Short labels for [DateTime.weekday] (1 = Monday … 7 = Sunday).
const kAttendanceWeekdayShortLabels = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

/// English full weekday names (1 = Monday … 7 = Sunday), for section headers and titles.
const kAttendanceWeekdayFullNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// Stored [AttendanceList.date] is **weekday-only**: Monday = 2024-01-01, … Sunday = 2024-01-07.
DateTime attendanceListDateForWeekday(int weekday) {
  final w = weekday.clamp(1, 7);
  return DateTime(2024, 1, w);
}

/// Newest-first: [AttendanceList.date] is weekday-only for new data, so [id] breaks ties.
int compareAttendanceListsNewestFirst(AttendanceList a, AttendanceList b) {
  final byDate = b.date.compareTo(a.date);
  if (byDate != 0) return byDate;
  return b.id.compareTo(a.id);
}

/// List status for QA workflow.
enum AttendanceListStatus { draft, active, closed }

/// Day, evening, or weekend cohort — stored on each list and used in naming.
enum AttendanceProgram {
  day,
  evening,
  weekend;

  String get label => switch (this) {
        AttendanceProgram.day => 'Day',
        AttendanceProgram.evening => 'Evening',
        AttendanceProgram.weekend => 'Weekend',
      };

  static AttendanceProgram fromStorage(String? v) {
    switch (v) {
      case 'evening':
        return AttendanceProgram.evening;
      case 'weekend':
        return AttendanceProgram.weekend;
      default:
        return AttendanceProgram.day;
    }
  }
}

/// One attendance list with one or more courses.
class AttendanceList {
  final String id;
  final String time;
  final String room;
  final String whoTaught;
  final DateTime date;

  /// Day / evening / weekend program (shown in list title with lecturer & day).
  final AttendanceProgram program;

  /// All courses in this list; students pick one when signing in.
  /// Nullable for hot-reload compatibility with older list instances.
  final List<String>? courses;
  final String year;
  final String sem;

  /// Optional: who created (QA officer). Null for legacy lists.
  final String? createdBy;

  /// Firebase Auth uid of the assigned lecturer; null for legacy lists (admin-only).
  final String? lecturerUid;

  /// Optional: expected participant count. Null for legacy.
  final int? expectedParticipants;

  /// draft = not yet used; active = has active session; closed = done.
  final AttendanceListStatus status;

  /// Normalized 4–8 character code the lecturer enters on Sign in → Lecturer.
  /// Null or empty = lecturer sign-in not configured for this list.
  final String? lecturerSignCode;

  /// When the lecturer last confirmed the class via lecturer code (optional).
  final DateTime? lecturerSignedAt;

  /// Primary label for this list (course unit name), shown as [displayTitle].
  final String? courseUnitName;

  AttendanceList({
    required this.id,
    required this.time,
    required this.room,
    required this.whoTaught,
    required this.date,
    this.program = AttendanceProgram.day,
    required this.courses,
    required this.year,
    required this.sem,
    this.createdBy,
    this.lecturerUid,
    this.expectedParticipants,
    this.status = AttendanceListStatus.draft,
    this.lecturerSignCode,
    this.lecturerSignedAt,
    this.courseUnitName,
  });

  bool get hasLecturerSignCode =>
      lecturerSignCode != null && lecturerSignCode!.isNotEmpty;

  bool get isLecturerSigned => lecturerSignedAt != null;

  /// Non-null list of courses (empty if null from old data).
  List<String> get coursesSafe => courses ?? const [];

  /// Class day (weekday), not a calendar session date.
  String get dateLabel => kAttendanceWeekdayShortLabels[date.weekday - 1];

  /// Weekday of [date] (locale-independent English, for titles).
  String get weekdayName =>
      kAttendanceWeekdayFullNames[date.weekday.clamp(1, 7) - 1];

  /// Primary line: lecturer · calendar weekday · program · room.
  String get listLabelLine =>
      '$whoTaught · $weekdayName · ${program.label} · $room';

  String get courseSummaryLine {
    final list = coursesSafe;
    if (list.isEmpty) return 'No courses';
    if (list.length == 1) return list.single;
    return '${list.length} courses';
  }

  /// Resolved course unit label (explicit field or single legacy course).
  String get effectiveCourseUnitName {
    final unit = courseUnitName?.trim() ?? '';
    if (unit.isNotEmpty) return unit;
    final list = coursesSafe;
    if (list.length == 1) {
      final only = list.single.trim();
      if (only.isNotEmpty) return only;
    }
    return '';
  }

  String get displayTitle {
    final unit = effectiveCourseUnitName;
    if (unit.isNotEmpty) return unit;
    return '$listLabelLine · $courseSummaryLine · $dateLabel $time';
  }

  /// Under [displayTitle]: lecturer name and room (e.g. "Dr. Smith · A101").
  String get displaySubtitle {
    final lecturer = whoTaught.trim();
    final r = room.trim();
    if (lecturer.isNotEmpty && r.isNotEmpty) return '$lecturer · $r';
    if (lecturer.isNotEmpty) return lecturer;
    if (r.isNotEmpty) return 'Room $r';
    return '';
  }

  /// Display label for year (e.g. "1" -> "Year 1").
  String get yearLabel => 'Year $year';
}

/// Status of a check-in session (code + location + expiry).
enum SessionStatus { active, closed }

/// A live check-in session: unique join code, location, expiry.
class AttendanceSession {
  final String id;
  final String listId;

  /// Join code shown to students: letter + two digits + letter (e.g. A12B).
  /// Legacy sessions may still use ###, ####, or L###.
  final String sessionCode;
  final double latitude;
  final double longitude;

  /// Allowed radius in meters (e.g. 50). Ignored when [remoteLearning] is true.
  final double radiusMeters;
  final DateTime startTime;
  final DateTime endTime;
  final SessionStatus status;
  final String createdBy;

  /// Long-distance learning: no GPS radius check; no session-code push notice.
  final bool remoteLearning;

  AttendanceSession({
    required this.id,
    required this.listId,
    required this.sessionCode,
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
    required this.startTime,
    required this.endTime,
    required this.status,
    required this.createdBy,
    this.remoteLearning = false,
  });

  bool get isExpired => DateTime.now().isAfter(endTime);
  bool get isActive => status == SessionStatus.active && !isExpired;

  /// Lecturer has not closed the session — students may join until [status] is closed,
  /// including the brief window after [endTime] before auto-close on the lecturer device.
  bool get isOpenForCheckIn => status == SessionStatus.active;

  /// Completed sessions that count toward student attendance percentage
  /// (ended by time or closed in Firestore).
  bool get countsTowardRollStats =>
      DateTime.now().isAfter(endTime) || status == SessionStatus.closed;
}

/// One check-in record: student + session + location.
class AttendanceRecord {
  final String id;
  final String sessionId;
  final String studentId;
  final String course;
  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final bool verified;

  /// Whether the student attended in person. `false` = auto-marked absent for
  /// the roll (no GPS expected on absent rows).
  final bool present;

  /// Present check-ins only: device/install id so one phone cannot record two
  /// students for the same session. Null for legacy or absent rows.
  final String? deviceId;

  AttendanceRecord({
    required this.id,
    required this.sessionId,
    required this.studentId,
    required this.course,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    this.verified = false,
    this.present = true,
    this.deviceId,
  });
}

/// Stable Firestore document id / in-app id: one row per student per session.
/// Same composite-key idea as `{sessionId}_{studentId}` in textbook schemas
/// (see `FirestoreCollections.attendanceRecords`).
String attendanceRecordIdForSessionStudent(String sessionId, String studentId) {
  return '${sessionId}_$studentId';
}

/// Present vs total rows in [AttendanceStore.attendanceRecords] for a registration.
class AttendanceRollStats {
  const AttendanceRollStats({required this.present, required this.total});

  final int present;
  final int total;

  int get percentRounded =>
      total <= 0 ? 0 : ((100 * present) / total).round().clamp(0, 100);
}

/// Roll stats for one [AttendanceList] (student profile, per-class breakdown).
class AttendanceListRollStats {
  const AttendanceListRollStats({
    required this.listId,
    required this.listTitle,
    required this.listSubtitle,
    required this.stats,
  });

  final String listId;
  final String listTitle;
  final String listSubtitle;
  final AttendanceRollStats stats;
}

/// Example join code for UI hints (letter + 2 digits + letter).
const kSessionJoinCodeExample = 'A12B';

/// Short description of the join-code shape for help text.
const kSessionJoinCodeFormatHint =
    'letter, two numbers, letter (e.g. $kSessionJoinCodeExample)';

/// Primary join-code pattern: one letter, two digits, one letter.
final RegExp kSessionJoinCodePrimaryPattern = RegExp(r'^[A-Z]\d{2}[A-Z]$');

/// Generates a new join code: letter + two digits + letter (e.g. A12B).
String generateSessionCode() {
  final rnd = Random();
  String letter() => String.fromCharCode(65 + rnd.nextInt(26));
  final digits = rnd.nextInt(100).toString().padLeft(2, '0');
  return '${letter()}$digits${letter()}';
}

/// Normalizes join-code input (strip spaces, uppercase letters; digits unchanged).
String normalizeSessionCodeInput(String raw) {
  return raw.trim().replaceAll(RegExp(r'\s'), '').toUpperCase();
}

/// Valid join codes: primary [A-Z][0-9]{2}[A-Z], plus legacy ### / #### / L###.
bool isValidJoinCodeFormat(String normalized) {
  if (kSessionJoinCodePrimaryPattern.hasMatch(normalized)) return true;
  return RegExp(r'^\d{3}$').hasMatch(normalized) ||
      RegExp(r'^\d{4}$').hasMatch(normalized) ||
      RegExp(r'^[A-Z]\d{3}$').hasMatch(normalized);
}

/// True when [normalized] matches the current join-code format (not legacy).
bool isPrimarySessionJoinCodeFormat(String normalized) {
  return kSessionJoinCodePrimaryPattern.hasMatch(normalized);
}

/// Validates student-chosen initials: 2–4 letters A–Z (spaces stripped).
bool isValidStudentInitials(String raw) {
  final t = normalizeSessionCodeInput(raw);
  return RegExp(r'^[A-Z]{2,4}$').hasMatch(t);
}

/// Fallback initials when loading legacy student docs without [initials].
String deriveStudentInitialsFromName(String name) {
  final parts =
      name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return 'NA';
  if (parts.length == 1) {
    final p = parts.single;
    if (p.length >= 2) return p.substring(0, 2).toUpperCase();
    return '${p.toUpperCase()}X';
  }
  return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
}

/// Initials for a new roster row when the student only enters their full name.
String initialsFromFullName(String name) {
  final derived = deriveStudentInitialsFromName(name);
  if (isValidStudentInitials(derived)) return derived;
  final letters = name.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
  if (letters.length >= 4) return letters.substring(0, 4);
  if (letters.length >= 2) return letters;
  if (letters.length == 1) return '${letters}X';
  return 'NA';
}

/// Student roster row: name from account registration + reg; initials derived from name; 3-digit code assigned.
class StudentRecord {
  final String id;
  final String name;
  final String registrationNumber;
  final String threeDigitCode;

  /// Uppercase 2–4 letters; set when the student joins the roster (derived from name).
  final String initials;

  StudentRecord({
    required this.id,
    required this.name,
    required this.registrationNumber,
    required this.threeDigitCode,
    required this.initials,
  });
}

/// Record of a student signing in to an attendance list for a specific course.
class SignInRecord {
  final String id;
  final String listId;
  final String studentId;

  /// Course (from the list's courses) they signed in for.
  final String course;
  final DateTime signedInAt;

  /// Denormalized for lecturer roster when the [students] doc is not loaded yet.
  final String? studentName;
  final String? registrationNumber;

  SignInRecord({
    required this.id,
    required this.listId,
    required this.studentId,
    required this.course,
    required this.signedInAt,
    this.studentName,
    this.registrationNumber,
  });

  SignInRecord copyWith({
    String? id,
    String? listId,
    String? studentId,
    String? course,
    DateTime? signedInAt,
    String? studentName,
    String? registrationNumber,
  }) {
    return SignInRecord(
      id: id ?? this.id,
      listId: listId ?? this.listId,
      studentId: studentId ?? this.studentId,
      course: course ?? this.course,
      signedInAt: signedInAt ?? this.signedInAt,
      studentName: studentName ?? this.studentName,
      registrationNumber: registrationNumber ?? this.registrationNumber,
    );
  }
}

/// In-memory store for attendance (lists, sessions, students, sign-ins, records).
class AttendanceStore {
  AttendanceStore._();

  static final List<AttendanceList> lists = [];
  static final List<AttendanceSession> sessions = [];
  static final List<StudentRecord> students = [];
  static final List<SignInRecord> signIns = [];
  static final List<AttendanceRecord> attendanceRecords = [];

  /// Built lazily; cleared by [invalidateLookupCaches] and targeted updates.
  static Map<String, AttendanceSession>? _sessionByIdMemo;
  static Map<String, AttendanceList>? _listByIdMemo;
  static Map<String, StudentRecord>? _studentByRegUpperMemo;

  /// Clears O(1) lookup caches after a full Firestore reload or rare bulk edits.
  static void invalidateLookupCaches() {
    _sessionByIdMemo = null;
    _listByIdMemo = null;
    _studentByRegUpperMemo = null;
  }

  static void _touchSessionMemo(AttendanceSession s) {
    _sessionByIdMemo ??= {};
    _sessionByIdMemo![s.id] = s;
  }

  static void _touchListMemo(AttendanceList list) {
    _listByIdMemo ??= {};
    _listByIdMemo![list.id] = list;
  }

  static String _newId() => DateTime.now().millisecondsSinceEpoch.toString();

  static int _codeCounter = 100;
  static String _newCode() {
    _codeCounter = (_codeCounter % 999) + 1;
    return _codeCounter.toString().padLeft(3, '0');
  }

  /// Used by repository after loading from Firestore to avoid code collisions.
  static void setCodeCounter(int value) {
    _codeCounter = value.clamp(100, 999);
  }

  static void addList(AttendanceList list) {
    lists.add(list);
    _touchListMemo(list);
  }

  static void replaceLists(List<AttendanceList> remoteLists) {
    lists
      ..clear()
      ..addAll(remoteLists);
    _listByIdMemo = null;
  }

  static void updateList(AttendanceList list) {
    final i = lists.indexWhere((e) => e.id == list.id);
    if (i >= 0) {
      lists[i] = list;
      _touchListMemo(list);
    }
  }

  static void removeList(String id) {
    final sessionIdsForList = sessions
        .where((s) => s.listId == id)
        .map((s) => s.id)
        .toSet();
    lists.removeWhere((l) => l.id == id);
    signIns.removeWhere((r) => r.listId == id);
    attendanceRecords.removeWhere((r) => sessionIdsForList.contains(r.sessionId));
    sessions.removeWhere((s) => s.listId == id);
    _listByIdMemo?.remove(id);
    invalidateLookupCaches();
  }

  // —— Session (code + location + expiry) ——
  static AttendanceSession? sessionById(String id) {
    _sessionByIdMemo ??= {for (final s in sessions) s.id: s};
    return _sessionByIdMemo![id];
  }

  static AttendanceSession? sessionByCode(String code) {
    final normalized = normalizeSessionCodeInput(code);
    if (!isValidJoinCodeFormat(normalized)) return null;
    try {
      return sessions.firstWhere((s) =>
          normalizeSessionCodeInput(s.sessionCode) == normalized && s.isActive);
    } catch (_) {
      return null;
    }
  }

  /// Latest joinable session for [code] (lecturer has not closed it).
  static AttendanceSession? sessionByCodeOpenForCheckIn(String code) {
    final normalized = normalizeSessionCodeInput(code);
    if (!isValidJoinCodeFormat(normalized)) return null;
    AttendanceSession? best;
    for (final s in sessions) {
      if (normalizeSessionCodeInput(s.sessionCode) != normalized) continue;
      if (!s.isOpenForCheckIn) continue;
      if (best == null || s.startTime.isAfter(best.startTime)) {
        best = s;
      }
    }
    return best;
  }

  static void addSession(AttendanceSession s) {
    sessions.add(s);
    _touchSessionMemo(s);
  }

  static void updateSession(AttendanceSession s) {
    final i = sessions.indexWhere((e) => e.id == s.id);
    if (i >= 0) {
      sessions[i] = s;
      _touchSessionMemo(s);
    }
  }

  static void closeSession(String sessionId) {
    final s = sessionById(sessionId);
    if (s == null) return;
    updateSession(AttendanceSession(
      id: s.id,
      listId: s.listId,
      sessionCode: s.sessionCode,
      latitude: s.latitude,
      longitude: s.longitude,
      radiusMeters: s.radiusMeters,
      startTime: s.startTime,
      endTime: s.endTime,
      status: SessionStatus.closed,
      createdBy: s.createdBy,
      remoteLearning: s.remoteLearning,
    ));
  }

  static bool hasCheckedIn(String sessionId, String studentId) {
    return attendanceRecords
        .any((r) => r.sessionId == sessionId && r.studentId == studentId);
  }

  /// True only when the student/session row exists and is **present** (not an
  /// absent roll row from [finalizeRollForSession] / backfill).
  static bool isPresentForSession(String sessionId, String studentId) {
    final r = attendanceRecordForSessionStudent(sessionId, studentId);
    return r != null && r.present;
  }

  /// True if this device already has a **present** row for the session for a
  /// **different** student (blocks proxy check-in on the same phone).
  static bool hasPresentCheckInForDevice(
    String sessionId,
    String deviceId,
    String studentId,
  ) {
    if (deviceId.trim().isEmpty) return false;
    return attendanceRecords.any(
      (r) =>
          r.sessionId == sessionId &&
          r.studentId != studentId &&
          r.present &&
          r.deviceId != null &&
          r.deviceId!.trim() == deviceId.trim(),
    );
  }

  /// Adds [r] only if there is no existing record for the same session and student.
  /// Used to prevent duplicate check-ins from concurrent taps (single isolate, sync add).
  static bool addAttendanceRecordIfAbsent(AttendanceRecord r) {
    if (hasCheckedIn(r.sessionId, r.studentId)) return false;
    attendanceRecords.add(r);
    return true;
  }

  static void removeAttendanceRecordById(String id) {
    attendanceRecords.removeWhere((x) => x.id == id);
  }

  static int recordCountForSession(String sessionId) {
    return attendanceRecords.where((r) => r.sessionId == sessionId).length;
  }

  /// Number of session check-ins for this list (across all its sessions).
  static int recordCountForList(String listId) {
    return attendanceRecords
        .where((r) => sessionById(r.sessionId)?.listId == listId)
        .length;
  }

  static void addAttendanceRecord(AttendanceRecord r) {
    attendanceRecords.add(r);
  }

  static void updateAttendanceRecord(AttendanceRecord r) {
    final i = attendanceRecords.indexWhere((x) => x.id == r.id);
    if (i >= 0) attendanceRecords[i] = r;
  }

  static List<AttendanceRecord> recordsForSession(String sessionId) {
    return attendanceRecords.where((r) => r.sessionId == sessionId).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  /// All sessions for a list, newest first (includes closed / expired).
  static List<AttendanceSession> sessionsForListNewestFirst(String listId) {
    return sessions.where((s) => s.listId == listId).toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
  }

  /// Distinct students who signed into this attendance list (any course).
  static Set<String> studentIdsSignedIntoList(String listId) {
    return signIns
        .where((s) => s.listId == listId)
        .map((s) => s.studentId)
        .toSet();
  }

  /// Course label for roll/absent row (first sign-in for that list, else first list course).
  static String courseForStudentOnList(String listId, String studentId) {
    for (final s in signIns) {
      if (s.listId == listId && s.studentId == studentId) {
        return s.course;
      }
    }
    final list = listById(listId);
    final cs = list?.coursesSafe ?? const <String>[];
    return cs.isNotEmpty ? cs.first : '';
  }

  /// Course chosen by the student for this list, if already enrolled.
  ///
  /// Unlike [courseForStudentOnList], this does not fallback to list defaults.
  static String? signedInCourseForStudentOnList(
      String listId, String studentId) {
    for (final s in signIns) {
      if (s.listId == listId && s.studentId == studentId) {
        return s.course;
      }
    }
    return null;
  }

  /// Whether student already enrolled on this list (any course).
  static bool hasStudentSignedIntoList(String listId, String studentId) {
    for (final s in signIns) {
      if (s.listId == listId && s.studentId == studentId) {
        return true;
      }
    }
    return false;
  }

  /// Earliest [SignInRecord.signedInAt] for this student on this list (any course).
  ///
  /// Used to detect sessions the student missed before joining (retroactive absent).
  static DateTime? earliestSignInAtForStudentOnList(
    String listId,
    String studentId,
  ) {
    DateTime? best;
    for (final s in signIns) {
      if (s.listId != listId || s.studentId != studentId) continue;
      if (best == null || s.signedInAt.isBefore(best)) {
        best = s.signedInAt;
      }
    }
    return best;
  }

  /// Minimum of [earliestSignInAtForStudentOnList] across [studentIds], or null.
  static DateTime? earliestSignInAtForAnyStudentOnList(
    String listId,
    Iterable<String> studentIds,
  ) {
    DateTime? best;
    for (final sid in studentIds) {
      final e = earliestSignInAtForStudentOnList(listId, sid);
      if (e == null) continue;
      if (best == null || e.isBefore(best)) best = e;
    }
    return best;
  }

  static AttendanceRecord? attendanceRecordForSessionStudent(
    String sessionId,
    String studentId,
  ) {
    for (final r in attendanceRecords) {
      if (r.sessionId == sessionId && r.studentId == studentId) return r;
    }
    return null;
  }

  /// Roster ∪ anyone with a row for this session (e.g. guest check-in).
  static Set<String> studentIdsForSessionRoll(String listId, String sessionId) {
    final ids = {...studentIdsSignedIntoList(listId)};
    for (final r in attendanceRecords) {
      if (r.sessionId == sessionId) ids.add(r.studentId);
    }
    return ids;
  }

  static Set<String> _studentIdsForRegistrationNormalized(String reg) {
    final key = reg.trim().toUpperCase();
    if (key.isEmpty) return {};
    final ids = students
        .where((s) => s.registrationNumber.trim().toUpperCase() == key)
        .map((s) => s.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    // Sign-ins may carry registration metadata before the roster row is hydrated.
    for (final si in signIns) {
      if (si.registrationNumber?.trim().toUpperCase() != key) continue;
      final sid = si.studentId.trim();
      if (sid.isNotEmpty) ids.add(sid);
    }
    return ids;
  }

  /// All roster ids for one registration (same lookup as profile attendance %).
  static Set<String> studentIdsForRegistrationNormalized(String reg) =>
      _studentIdsForRegistrationNormalized(reg);

  /// True when the student has joined at least one list or has attendance rows.
  static bool hasAttendanceDataForRegistrationNormalized(String reg) {
    final key = reg.trim().toUpperCase();
    if (key.isEmpty) return false;
    if (signIns.any((si) => si.registrationNumber?.trim().toUpperCase() == key)) {
      return true;
    }
    final ids = _studentIdsForRegistrationNormalized(reg);
    if (ids.isEmpty) return false;
    for (final sid in ids) {
      if (signIns.any((si) => si.studentId == sid)) return true;
      if (attendanceRecords.any((r) => r.studentId == sid)) return true;
    }
    return false;
  }

  /// True when cached sessions exist for lists the student has joined.
  /// Profile % and session history need this — sign-in alone is not enough.
  static bool hasStudentSessionHistoryForRegistrationNormalized(String reg) {
    final ids = _studentIdsForRegistrationNormalized(reg);
    if (ids.isEmpty) return false;
    final enrolledListIds = _enrolledListIdsForStudentIds(ids);
    if (enrolledListIds.isEmpty) return false;
    return sessions.any((s) => enrolledListIds.contains(s.listId));
  }

  static Set<String> _enrolledListIdsForStudentIds(Set<String> studentIds) {
    final enrolledListIds = <String>{};
    for (final sid in studentIds) {
      for (final si in signIns) {
        if (si.studentId == sid) enrolledListIds.add(si.listId);
      }
      for (final r in attendanceRecords) {
        if (r.studentId != sid) continue;
        final lid = sessionById(r.sessionId)?.listId;
        if (lid != null) enrolledListIds.add(lid);
      }
    }
    return enrolledListIds;
  }

  /// Attendance % for one list: all completed sessions on the list, including
  /// sessions that ended before the student joined (counted as missed/absent).
  static AttendanceRollStats rollStatsForRegistrationOnList(
    String reg,
    String listId, {
    Set<String>? studentIds,
  }) {
    final ids = studentIds ?? _studentIdsForRegistrationNormalized(reg);
    if (ids.isEmpty) {
      return const AttendanceRollStats(present: 0, total: 0);
    }

    var total = 0;
    var present = 0;
    final enrolledAt = earliestSignInAtForAnyStudentOnList(listId, ids);
    final completedSessions = sessionsForListNewestFirst(listId)
        .where((s) => s.countsTowardRollStats)
        .toList();
    final countedSessionIds = <String>{};

    AttendanceRecord? bestRecordForSession(String sessionId) {
      AttendanceRecord? best;
      for (final sid in ids) {
        final r = attendanceRecordForSessionStudent(sessionId, sid);
        if (r == null) continue;
        if (best == null || (r.present && !best.present)) {
          best = r;
        }
      }
      return best;
    }

    final now = DateTime.now();
    for (final sess in completedSessions) {
      final rec = bestRecordForSession(sess.id);
      if (rec != null) {
        total++;
        if (rec.present) present++;
        countedSessionIds.add(sess.id);
        continue;
      }
      final graceExpired = PendingRetention.sessionGraceExpired(sess.endTime, now);
      final missedBeforeJoin =
          enrolledAt != null && sess.endTime.isBefore(enrolledAt);
      if (!missedBeforeJoin && !graceExpired) continue;
      total++;
      countedSessionIds.add(sess.id);
    }

    for (final sid in ids) {
      for (final r in attendanceRecords) {
        if (r.studentId != sid) continue;
        if (countedSessionIds.contains(r.sessionId)) continue;
        final sess = sessionById(r.sessionId);
        if (sess == null ||
            sess.listId != listId ||
            !sess.countsTowardRollStats) {
          continue;
        }
        total++;
        if (r.present) present++;
        countedSessionIds.add(r.sessionId);
      }
    }

    return AttendanceRollStats(present: present, total: total);
  }

  /// Per-list attendance breakdown for a registration (profile screen).
  static List<AttendanceListRollStats> rollStatsPerListForRegistrationNormalized(
    String reg,
  ) {
    final ids = _studentIdsForRegistrationNormalized(reg);
    if (ids.isEmpty) return const [];

    final enrolledListIds = _enrolledListIdsForStudentIds(ids);
    if (enrolledListIds.isEmpty) return const [];

    final lists = <AttendanceList>[];
    for (final listId in enrolledListIds) {
      final list = listById(listId);
      if (list != null) lists.add(list);
    }
    lists.sort(compareAttendanceListsNewestFirst);

    return [
      for (final list in lists)
        AttendanceListRollStats(
          listId: list.id,
          listTitle: list.displayTitle,
          listSubtitle: list.displaySubtitle,
          stats: rollStatsForRegistrationOnList(reg, list.id, studentIds: ids),
        ),
    ];
  }

  /// Overall attendance % across all lists the student has joined.
  static AttendanceRollStats rollStatsForRegistrationNormalized(String reg) {
    var total = 0;
    var present = 0;
    for (final row in rollStatsPerListForRegistrationNormalized(reg)) {
      total += row.stats.total;
      present += row.stats.present;
    }
    return AttendanceRollStats(present: present, total: total);
  }

  static List<AttendanceList> listsForYearSem(String year, String sem) {
    return lists.where((l) => l.year == year && l.sem == sem).toList()
      ..sort((a, b) {
        final c = a.date.compareTo(b.date);
        if (c != 0) return c;
        return a.id.compareTo(b.id);
      });
  }

  static StudentRecord? findStudentByReg(String reg) {
    final key = reg.trim().toUpperCase();
    if (key.isEmpty) return null;
    _studentByRegUpperMemo ??= {
      for (final s in students) s.registrationNumber.trim().toUpperCase(): s,
    };
    return _studentByRegUpperMemo![key];
  }

  static StudentRecord? findStudentByCode(String code) {
    try {
      return students.firstWhere(
        (s) => s.threeDigitCode == code.trim(),
      );
    } catch (_) {
      return null;
    }
  }

  static void upsertStudent(StudentRecord student) {
    final i = students.indexWhere((s) => s.id == student.id);
    if (i >= 0) {
      students[i] = student;
    } else {
      students.add(student);
    }
    _studentByRegUpperMemo = null;
  }

  static StudentRecord registerStudent(
    String name,
    String registrationNumber,
    String initials,
  ) {
    final dup = findStudentByReg(registrationNumber);
    if (dup != null) {
      return dup;
    }
    final ini = normalizeSessionCodeInput(initials);
    final reg = registrationNumber.trim().toUpperCase();
    String code;
    do {
      code = _newCode();
    } while (students.any((s) => s.threeDigitCode == code));
    // Stable id = registration number so lecturers can load students/{reg} reliably.
    final id = reg.isNotEmpty ? reg : _newId();
    final record = StudentRecord(
      id: id,
      name: name.trim(),
      registrationNumber: reg,
      threeDigitCode: code,
      initials: ini,
    );
    students.add(record);
    _studentByRegUpperMemo = null;
    return record;
  }

  static AttendanceList? listById(String id) {
    _listByIdMemo ??= {for (final l in lists) l.id: l};
    return _listByIdMemo![id];
  }

  /// Lightweight hot-path index for O(1) student lookup in UI/reports.
  static Map<String, StudentRecord> studentMapById() {
    return <String, StudentRecord>{for (final s in students) s.id: s};
  }

  /// Roster lookup for one list: store students plus sign-in metadata fallbacks.
  static Map<String, StudentRecord> rosterStudentMapForList(String listId) {
    final byId = studentMapById();
    for (final si in signIns) {
      if (si.listId != listId) continue;
      final sid = si.studentId.trim();
      if (sid.isEmpty) continue;

      final signInName = si.studentName?.trim() ?? '';
      final signInReg = si.registrationNumber?.trim().toUpperCase() ?? '';
      final existing = byId[sid];

      if (existing != null) {
        final nameBetter = signInName.isNotEmpty &&
            (existing.name.trim().isEmpty ||
                existing.name.trim() == 'Unknown');
        final regBetter = signInReg.isNotEmpty &&
            (existing.registrationNumber.trim().isEmpty ||
                existing.registrationNumber.trim() == '—');
        if (!nameBetter && !regBetter) continue;
        byId[sid] = StudentRecord(
          id: existing.id,
          name: nameBetter ? signInName : existing.name,
          registrationNumber:
              regBetter ? signInReg : existing.registrationNumber,
          threeDigitCode: existing.threeDigitCode,
          initials: nameBetter
              ? deriveStudentInitialsFromName(signInName)
              : existing.initials,
        );
        continue;
      }

      if (signInName.isEmpty && signInReg.isEmpty) continue;
      byId[sid] = StudentRecord(
        id: sid,
        name: signInName.isNotEmpty ? signInName : 'Unknown',
        registrationNumber: signInReg.isNotEmpty ? signInReg : '—',
        threeDigitCode: '000',
        initials: signInName.isNotEmpty
            ? deriveStudentInitialsFromName(signInName)
            : '??',
      );
    }
    return byId;
  }

  /// Lightweight hot-path index for O(1) session lookup in UI/reports.
  static Map<String, AttendanceSession> sessionMapById() {
    return <String, AttendanceSession>{for (final s in sessions) s.id: s};
  }

  static bool hasSignedIn(String listId, String studentId, String course) {
    return signIns.any((r) =>
        r.listId == listId && r.studentId == studentId && r.course == course);
  }

  static void addSignIn(String listId, String studentId, String course) {
    signIns.add(SignInRecord(
      id: _newId(),
      listId: listId,
      studentId: studentId,
      course: course,
      signedInAt: DateTime.now(),
    ));
  }

  /// Add a sign-in record with a specific id (used by Firestore repository).
  static void addSignInRecord(SignInRecord record) {
    signIns.add(record);
  }

  static int signInCountForList(String listId) {
    return signIns.where((r) => r.listId == listId).length;
  }

  /// All sign-ins for a student (for "my attendance" view).
  static List<SignInRecord> signInsForStudent(String studentId) {
    return signIns.where((r) => r.studentId == studentId).toList()
      ..sort((a, b) => b.signedInAt.compareTo(a.signedInAt));
  }

  /// Attendance grouped by course name for a student.
  /// Key: course name, Value: list of sign-in records for that course.
  static Map<String, List<SignInRecord>> attendanceByCourseForStudent(
      String studentId) {
    final byCourse = <String, List<SignInRecord>>{};
    for (final r in signInsForStudent(studentId)) {
      final course = r.course;
      byCourse.putIfAbsent(course, () => []).add(r);
    }
    return byCourse;
  }
}
