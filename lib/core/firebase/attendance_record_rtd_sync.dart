import '../../features/attendance/models/attendance_models.dart';

/// Parse official attendance rows from Realtime Database payloads.
abstract final class AttendanceRecordRtdSync {
  static const recordsRoot = 'attendance_records';
  static const statsRoot = 'attendance_roll_stats';

  static String sessionRecordsPath(String sessionId) =>
      '$recordsRoot/by_session/$sessionId';

  static String studentRecordsPath(String studentId) =>
      '$recordsRoot/by_student/$studentId';

  static String sessionStatsPath(String sessionId) =>
      '$statsRoot/by_session/$sessionId';

  static String listSessionStatsPath(String listId, String sessionId) =>
      '$statsRoot/by_list/$listId/$sessionId';

  static String studentRollStatsPath(String studentId) =>
      '$statsRoot/by_student/$studentId';

  static String studentListRollStatsPath(String studentId, String listId) =>
      '$statsRoot/by_student/$studentId/by_list/$listId';

  static AttendanceRecord? recordFromRtdValue({
    required String sessionId,
    required String studentId,
    required dynamic value,
  }) {
    if (value is! Map) return null;
    final map = value.map((k, v) => MapEntry(k.toString(), v));
    final sid = (map['sessionId'] as String?)?.trim().isNotEmpty == true
        ? (map['sessionId'] as String).trim()
        : sessionId.trim();
    final stu = (map['studentId'] as String?)?.trim().isNotEmpty == true
        ? (map['studentId'] as String).trim()
        : studentId.trim();
    if (sid.isEmpty || stu.isEmpty) return null;

    final rid = (map['recordId'] as String?)?.trim().isNotEmpty == true
        ? (map['recordId'] as String).trim()
        : attendanceRecordIdForSessionStudent(sid, stu);

    final tsRaw = map['timestamp'];
    final DateTime ts;
    if (tsRaw is int) {
      ts = DateTime.fromMillisecondsSinceEpoch(tsRaw);
    } else if (tsRaw is num) {
      ts = DateTime.fromMillisecondsSinceEpoch(tsRaw.round());
    } else {
      ts = DateTime.now();
    }

    return AttendanceRecord(
      id: rid,
      sessionId: sid,
      studentId: stu,
      course: (map['course'] as String?) ?? '',
      timestamp: ts,
      latitude: (map['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (map['longitude'] as num?)?.toDouble() ?? 0,
      verified: map['verified'] == true,
      present: map['present'] == true,
      deviceId: (map['deviceId'] as String?)?.trim(),
    );
  }
}
