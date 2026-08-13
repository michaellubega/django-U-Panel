/// Device-local cache TTLs and fetch-once rules for U-Panel.
abstract final class SmartCachePolicy {
  SmartCachePolicy._();

  /// Profile and notices — refresh from server at most once per week.
  static const Duration profileAndNoticesTtl = Duration(days: 7);

  /// Staff attendance list metadata — refresh often so QA/lecturer hubs stay current.
  static const Duration staffAttendanceListsTtl = Duration(seconds: 90);

  /// Staff list metadata background refresh even when inside [staffAttendanceListsTtl].
  static const Duration staffAttendanceListsSoftStale = Duration(seconds: 30);

  /// Course names, attendance rows, and university meta stay until explicitly
  /// removed or the user signs out (see [AttendanceLocalSnapshot]).
  static const Duration forever = Duration(days: 36500);

  static bool isWithinTtl(DateTime? cachedAt, Duration ttl) {
    if (cachedAt == null) return false;
    return DateTime.now().difference(cachedAt) < ttl;
  }

  static bool isExpired(DateTime? cachedAt, Duration ttl) =>
      !isWithinTtl(cachedAt, ttl);

  /// True when a scoped entity has already been pulled from the server.
  static bool wasFetchedBefore(
    Set<String> registry,
    String key, {
    bool force = false,
  }) {
    if (force) return false;
    return registry.contains(key.trim());
  }
}
