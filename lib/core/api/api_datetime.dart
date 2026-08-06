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
