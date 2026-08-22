import 'dart:convert';

import '../../../core/cache/smart_cache_policy.dart';
import '../../../core/storage/attendance_local_queues.dart';
import '../../../core/storage/local_json_decode.dart';
import '../create_notice_screen.dart';
import 'notices_repository.dart';

const _storagePrefix = 'notices_disk_cache_v1_';

/// Persists notice rows for up to [SmartCachePolicy.profileAndNoticesTtl].
class NoticesDiskCache {
  NoticesDiskCache._();

  static String _key(String userKey) => '$_storagePrefix${userKey.trim()}';

  static Future<({List<NoticeRecord> notices, DateTime cachedAt})?> load(
    String userKey,
  ) async {
    final key = _key(userKey);
    final raw = await AttendanceLocalQueues.readString(key);
    if (raw == null || raw.isEmpty) return null;
    final decoded = await decodeStoredJson<Map<String, dynamic>>(
      raw: raw,
      storageKey: key,
      removeKey: AttendanceLocalQueues.removeKey,
      parse: (value) => value is Map ? Map<String, dynamic>.from(value) : {},
      debugLabel: 'NoticesDiskCache',
    );
    if (decoded == null || decoded.isEmpty) return null;
    final cachedAtRaw = decoded['cachedAt'] as String?;
    final cachedAt = cachedAtRaw == null ? null : DateTime.tryParse(cachedAtRaw);
    if (cachedAt == null) return null;
    final rows = decoded['notices'];
    if (rows is! List) return null;
    final out = <NoticeRecord>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final id = (row['id'] as String?)?.trim() ?? '';
      if (id.isEmpty) continue;
      try {
        final createdRaw = row['createdAt'] as String?;
        final created = createdRaw == null ? null : DateTime.tryParse(createdRaw);
        if (created == null) continue;
        final schedRaw = row['scheduledFor'] as String?;
        final expiresRaw = row['expiresAt'] as String?;
        final slotRaw = row['scheduledSlotAt'] as String?;
        final audRaw = (row['audience'] as String?)?.trim().toLowerCase();
        final NoticeAudienceKind audience;
        if (audRaw == 'classlist' || audRaw == 'class_list') {
          audience = NoticeAudienceKind.classList;
        } else if (audRaw == 'student' || audRaw == 'targetstudent') {
          audience = NoticeAudienceKind.student;
        } else if (audRaw == 'kiuadmins' || audRaw == 'kiu_admins') {
          audience = NoticeAudienceKind.kiuAdmins;
        } else {
          audience = NoticeAudienceKind.allAppUsers;
        }
        out.add(
          NoticeRecord(
            id: id,
            title: (row['title'] as String?)?.trim() ?? '',
            body: (row['body'] as String?)?.trim() ?? '',
            author: (row['author'] as String?)?.trim() ?? 'Admin',
            createdAt: created,
            scheduledFor:
                schedRaw == null ? null : DateTime.tryParse(schedRaw),
            sendPush: row['sendPush'] == true,
            audience: audience,
            targetListId: (row['targetListId'] as String?)?.trim(),
            targetListTitle: (row['targetListTitle'] as String?)?.trim(),
            targetStudentId: (row['targetStudentId'] as String?)?.trim(),
            sessionCode: (row['sessionCode'] as String?)?.trim(),
            sessionId: (row['sessionId'] as String?)?.trim(),
            targetLecturerUid: (row['targetLecturerUid'] as String?)?.trim(),
            scheduledSlotAt:
                slotRaw == null ? null : DateTime.tryParse(slotRaw),
            kind: (row['kind'] as String?)?.trim(),
            expiresAt:
                expiresRaw == null ? null : DateTime.tryParse(expiresRaw),
          ),
        );
      } catch (_) {}
    }
    return (notices: out, cachedAt: cachedAt);
  }

  static Future<void> save({
    required String userKey,
    required List<NoticeRecord> notices,
    DateTime? cachedAt,
  }) async {
    final key = _key(userKey);
    final at = (cachedAt ?? DateTime.now()).toUtc();
    final payload = <String, dynamic>{
      'cachedAt': at.toIso8601String(),
      'notices': [
        for (final n in notices)
          <String, dynamic>{
            'id': n.id,
            'title': n.title,
            'body': n.body,
            'author': n.author,
            'createdAt': n.createdAt.toUtc().toIso8601String(),
            if (n.scheduledFor != null)
              'scheduledFor': scheduledAtUtc(n.scheduledFor!),
            'sendPush': n.sendPush,
            'audience': _audienceField(n.audience),
            if (n.targetListId != null) 'targetListId': n.targetListId,
            if (n.targetListTitle != null) 'targetListTitle': n.targetListTitle,
            if (n.targetStudentId != null) 'targetStudentId': n.targetStudentId,
            if (n.sessionCode != null) 'sessionCode': n.sessionCode,
            if (n.sessionId != null) 'sessionId': n.sessionId,
            if (n.targetLecturerUid != null)
              'targetLecturerUid': n.targetLecturerUid,
            if (n.scheduledSlotAt != null)
              'scheduledSlotAt': scheduledAtUtc(n.scheduledSlotAt!),
            if (n.kind != null) 'kind': n.kind,
            if (n.expiresAt != null) 'expiresAt': scheduledAtUtc(n.expiresAt!),
          },
      ],
    };
    await AttendanceLocalQueues.writeString(key, jsonEncode(payload));
  }

  static String scheduledAtUtc(DateTime d) => d.toUtc().toIso8601String();

  static String _audienceField(NoticeAudienceKind k) {
    switch (k) {
      case NoticeAudienceKind.classList:
        return 'classList';
      case NoticeAudienceKind.student:
        return 'student';
      case NoticeAudienceKind.allAppUsers:
        return 'allAppUsers';
      case NoticeAudienceKind.kiuAdmins:
        return 'kiuAdmins';
    }
  }

  static Future<void> removeNotice(String userKey, String noticeId) async {
    final id = noticeId.trim();
    if (id.isEmpty) return;
    final cached = await load(userKey);
    if (cached == null) return;
    final next =
        cached.notices.where((n) => n.id != id).toList(growable: false);
    if (next.length == cached.notices.length) return;
    await save(
      userKey: userKey,
      notices: next,
      cachedAt: cached.cachedAt,
    );
  }

  static Future<void> clear(String userKey) async {
    await AttendanceLocalQueues.removeKey(_key(userKey));
  }

  static List<NoticeRecord> mergeNotices({
    required List<NoticeRecord> existing,
    required List<NoticeRecord> incoming,
  }) {
    final byId = {for (final n in existing) n.id: n};
    for (final n in incoming) {
      byId[n.id] = n;
    }
    final merged = byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return merged;
  }
}
