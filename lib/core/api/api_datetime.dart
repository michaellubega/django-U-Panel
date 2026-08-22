/// Parse date/time fields from Django API JSON (replaces Firestore [Timestamp]).
DateTime? apiDateFromField(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
  }
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  return null;
}

/// Serialize a [DateTime] for API writes (replaces [Timestamp.fromDate]).
String apiDateToField(DateTime value) => value.toUtc().toIso8601String();

/// Calendar date only (`YYYY-MM-DD`) in local time — for weekday-only fields
/// (attendance list class day) that must not shift across timezones.
String apiDateOnlyToField(DateTime value) {
  final local = value.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
