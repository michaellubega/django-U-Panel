import 'dart:async';

/// RTD listeners disabled — Django API uses polling via [AttendanceRemoteRecordWatch].
class AttendanceRtdRecordWatch {
  AttendanceRtdRecordWatch._();

  static final AttendanceRtdRecordWatch instance = AttendanceRtdRecordWatch._();

  bool get isRunning => false;

  Future<void> watchActiveSessionRecords(String sessionId) async {}

  Future<void> clearActiveSessionWatch() async {}

  Future<void> start() async {}

  Future<void> refreshIfNeeded() async {}

  Future<void> primeAfterStudentCheckIn({
    required String studentId,
    String? sessionId,
    String? listId,
  }) async {}

  Future<void> stop({bool keepActiveSession = false}) async {}
}
