/// How long unverifiable pending check-ins / session-code rows are kept locally.
class PendingRetention {
  PendingRetention._();

  static const Duration unverifiedPending = Duration(days: 7);

  static DateTime pendingSinceOr(DateTime capturedAt, DateTime? existing) =>
      existing ?? capturedAt;

  static bool isExpired(DateTime pendingSince, DateTime now) =>
      now.difference(pendingSince) > unverifiedPending;

  static int daysRemaining(DateTime pendingSince, DateTime now) {
    final left = unverifiedPending - now.difference(pendingSince);
    if (left.isNegative) return 0;
    return left.inDays;
  }
}
