import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _lessonReminderSnapshotKey = 'lesson_reminder_snapshot_v1';

/// Lightweight snapshot persisted for background lesson reminder resync.
class PersistedLessonReminder {
  const PersistedLessonReminder({
    required this.id,
    required this.fireAtIso,
    required this.title,
    required this.body,
  });

  final int id;
  final String fireAtIso;
  final String title;
  final String body;

  Map<String, dynamic> toJson() => {
        'id': id,
        'fireAtIso': fireAtIso,
        'title': title,
        'body': body,
      };

  static PersistedLessonReminder? fromJson(Map<String, dynamic> m) {
    final id = m['id'];
    final fireAtIso = m['fireAtIso'] as String?;
    final title = m['title'] as String?;
    final body = m['body'] as String?;
    if (id is! int || fireAtIso == null || title == null || body == null) {
      return null;
    }
    return PersistedLessonReminder(
      id: id,
      fireAtIso: fireAtIso,
      title: title,
      body: body,
    );
  }
}

Future<void> persistLessonReminders(List<PersistedLessonReminder> items) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _lessonReminderSnapshotKey,
    jsonEncode(items.map((e) => e.toJson()).toList()),
  );
  await prefs.setStringList(
    'lesson_reminder_ids_v1',
    items.map((e) => '${e.id}').toList(),
  );
}

Future<List<PersistedLessonReminder>> loadPersistedLessonReminders() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_lessonReminderSnapshotKey);
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      await prefs.remove(_lessonReminderSnapshotKey);
      return const [];
    }
    final out = <PersistedLessonReminder>[];
    for (final e in decoded) {
      if (e is! Map) continue;
      final item = PersistedLessonReminder.fromJson(
        Map<String, dynamic>.from(e),
      );
      if (item != null) out.add(item);
    }
    return out;
  } on FormatException catch (e) {
    if (kDebugMode) {
      debugPrint(
        'loadPersistedLessonReminders: dropped corrupt snapshot: $e',
      );
    }
    await prefs.remove(_lessonReminderSnapshotKey);
    return const [];
  } catch (_) {
    await prefs.remove(_lessonReminderSnapshotKey);
    return const [];
  }
}

Future<Set<int>> loadPreviousLessonReminderIds() async {
  final prefs = await SharedPreferences.getInstance();
  final ids = prefs.getStringList('lesson_reminder_ids_v1') ?? const [];
  return ids.map(int.tryParse).whereType<int>().toSet();
}

Future<void> clearLessonReminderSnapshot() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_lessonReminderSnapshotKey);
  await prefs.remove('lesson_reminder_ids_v1');
}
