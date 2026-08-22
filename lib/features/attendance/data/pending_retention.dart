/// How long sessions and check-ins are kept locally while awaiting verification.
class PendingRetention {
  PendingRetention._();

  /// All attendance sessions and check-in evidence stay for seven days.
  static const Duration sessionRetention = Duration(days: 7);

  /// Same window for queued / approved check-ins awaiting or after verification.
  static const Duration checkInRetention = sessionRetention;

  /// Legacy alias used across roll grace and awaiting-session claims.
  static const Duration unverifiedPending = checkInRetention;

  static DateTime pendingSinceOr(DateTime capturedAt, DateTime? existing) =>
      existing ?? capturedAt;

  static bool isExpired(DateTime pendingSince, DateTime now) =>
      now.difference(pendingSince) > checkInRetention;

  static int daysRemaining(DateTime pendingSince, DateTime now) {
    final left = checkInRetention - now.difference(pendingSince);
    if (left.isNegative) return 0;
    return left.inDays;
  }

  /// True when [sessionEnd] is older than the seven-day session window.
  static bool sessionGraceExpired(DateTime sessionEnd, DateTime now) =>
      isExpired(sessionEnd, now);

  static bool isWithinRetention(DateTime capturedAt, DateTime now) =>
      !isExpired(capturedAt, now);
}
