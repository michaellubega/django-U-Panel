/// Result of [AttendanceRepository.submitStudentCheckInWithOfflineSupport].
enum StudentOfflineCheckInOutcome {
  /// Attempt accepted; official [attendanceRecords] row synced from Firebase.
  success,

  /// Attempt uploaded; local row stays pending until Firebase confirms.
  submittedPendingVerification,

  /// Server rejected the attempt (roster/sign-in or other non-session issues).
  rejectedVerification,

  /// Capture time, GPS, or session code does not match the active class session.
  sessionMismatch,

  queuedOffline,
  duplicate,
  deviceBlocked,
}
