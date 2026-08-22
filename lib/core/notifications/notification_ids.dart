/// Stable local notification ids for U-Panel.
class NotificationIds {
  NotificationIds._();

  static const pendingOfflineReminder = 880024;
  static const pendingOfflineBackground = 880025;

  static const lessonLecturerBase = 881000;
  static const lessonQaBase = 891000;
  static const lessonIdSpan = 9000;

  static int lessonLecturer(String listId, DateTime day) =>
      lessonLecturerBase + _stableHash('lect_${listId}_${_dayKey(day)}') % lessonIdSpan;

  static int lessonQa(String listId, DateTime day) =>
      lessonQaBase + _stableHash('qa_${listId}_${_dayKey(day)}') % lessonIdSpan;

  static String _dayKey(DateTime day) =>
      '${day.year}${day.month.toString().padLeft(2, '0')}${day.day.toString().padLeft(2, '0')}';

  static int _stableHash(String input) {
    var hash = 0;
    for (final unit in input.codeUnits) {
      hash = 0x1fffffff & (hash + unit);
      hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
      hash ^= hash >> 6;
    }
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    hash ^= hash >> 11;
    hash = 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
    return hash.abs();
  }
}
