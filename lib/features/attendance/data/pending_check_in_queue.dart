import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/notifications/pending_work_notification_hooks.dart';
import '../../../core/storage/attendance_local_queues.dart';
import '../../../core/storage/local_json_decode.dart';
import '../models/attendance_models.dart';
import 'pending_retention.dart';

const _maxEntries = 200;

/// Serializable pending present check-in when Firestore is unreachable.
///
/// Evidence (time + GPS) was captured at enrollment time; the sync worker
/// re-validates against the session geometry when draining the queue.
class PendingCheckInEntry {
  PendingCheckInEntry({
    required this.id,
    required this.sessionId,
    required this.studentId,
    required this.listId,
    required this.course,
    required this.capturedAt,
    required this.latitude,
    required this.longitude,
    required this.deviceId,
    DateTime? pendingSince,
  }) : pendingSince = pendingSince ?? capturedAt;

  final String id;
  final String sessionId;
  final String studentId;
  final String listId;
  final String course;
  final DateTime capturedAt;
  final double latitude;
  final double longitude;
  final String deviceId;

  /// When this row started waiting (session missing or upload pending).
  final DateTime pendingSince;

  AttendanceRecord toAttendanceRecord() => AttendanceRecord(
        id: id,
        sessionId: sessionId,
        studentId: studentId,
        course: course,
        timestamp: capturedAt,
        latitude: latitude,
        longitude: longitude,
        verified: false,
        present: true,
        deviceId: deviceId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'studentId': studentId,
        'listId': listId,
        'course': course,
        'capturedAt': capturedAt.toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        'deviceId': deviceId,
        'pendingSince': pendingSince.toIso8601String(),
      };

  static PendingCheckInEntry? fromJson(Map<String, dynamic> m) {
    try {
      final id = m['id'] as String?;
      final sessionId = m['sessionId'] as String?;
      final studentId = m['studentId'] as String?;
      final listId = m['listId'] as String?;
      final course = m['course'] as String?;
      final cap = m['capturedAt'] as String?;
      final lat = (m['latitude'] as num?)?.toDouble();
      final lng = (m['longitude'] as num?)?.toDouble();
      final deviceId = m['deviceId'] as String?;
      if (id == null ||
          sessionId == null ||
          studentId == null ||
          listId == null ||
          course == null ||
          cap == null ||
          lat == null ||
          lng == null ||
          deviceId == null) {
        return null;
      }
      final captured = DateTime.parse(cap);
      final sinceRaw = m['pendingSince'] as String?;
      final since = sinceRaw != null
          ? DateTime.tryParse(sinceRaw)
          : null;
      return PendingCheckInEntry(
        id: id,
        sessionId: sessionId,
        studentId: studentId,
        listId: listId,
        course: course,
        capturedAt: captured,
        latitude: lat,
        longitude: lng,
        deviceId: deviceId,
        pendingSince: PendingRetention.pendingSinceOr(captured, since),
      );
    } catch (_) {
      return null;
    }
  }
}

class PendingCheckInQueue {
  PendingCheckInQueue._();

  static Future<bool> containsRecordId(String recordId) async {
    final id = recordId.trim();
    if (id.isEmpty) return false;
    final all = await loadAll();
    return all.any((e) => e.id == id);
  }

  static Future<List<PendingCheckInEntry>> loadAll() async {
    final raw =
        await AttendanceLocalQueues.readString(AttendanceLocalQueues.checkInsJsonKey);
    if (raw == null || raw.isEmpty) return [];
    final list = await decodeStoredJson<List<dynamic>>(
      raw: raw,
      storageKey: AttendanceLocalQueues.checkInsJsonKey,
      removeKey: AttendanceLocalQueues.removeKey,
      parse: (decoded) => decoded is List ? decoded : const <dynamic>[],
      debugLabel: 'PendingCheckInQueue',
    );
    if (list == null || list.isEmpty) return [];
    final out = <PendingCheckInEntry>[];
    for (final e in list) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final ent = PendingCheckInEntry.fromJson(m);
      if (ent != null) out.add(ent);
    }
    return out;
  }

  static Future<void> saveAll(List<PendingCheckInEntry> items) async {
    final trimmed = items.length > _maxEntries
        ? items.sublist(items.length - _maxEntries)
        : items;
    if (trimmed.length != items.length) {
      debugPrint(
        'PendingCheckInQueue: dropped ${items.length - trimmed.length} old item(s) due to capacity $_maxEntries.',
      );
    }
    await AttendanceLocalQueues.writeString(
      AttendanceLocalQueues.checkInsJsonKey,
      jsonEncode(trimmed.map((e) => e.toJson()).toList()),
    );
  }

  /// Upsert by [entry.id] (stable per session+student).
  static Future<void> enqueue(PendingCheckInEntry entry) async {
    final all = await loadAll();
    all.removeWhere((e) => e.id == entry.id);
    all.add(entry);
    await saveAll(all);
    notifyPendingWorkEnqueued();
  }

  static Future<void> removeById(String id) async {
    final all = await loadAll();
    all.removeWhere((e) => e.id == id);
    await saveAll(all);
    notifyPendingWorkQueuesChanged();
  }

  static Future<void> clear() async {
    await AttendanceLocalQueues.removeKey(AttendanceLocalQueues.checkInsJsonKey);
  }
}
