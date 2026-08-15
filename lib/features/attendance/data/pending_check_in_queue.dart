import 'dart:convert';
import 'dart:async';

import '../../../core/notifications/pending_work_notification_hooks.dart';
import '../../../core/storage/attendance_local_queues.dart';
import '../../../core/storage/local_json_decode.dart';
import '../models/attendance_models.dart';
import 'pending_retention.dart';

enum PendingCheckInQueueStatus {
  queued,
  approved,
}

/// Serializable pending present check-in when upload or verification is delayed.
///
/// Evidence (time + GPS) was captured at check-in time; the sync worker
/// re-validates against the session when draining the queue. Rows are kept
/// for [PendingRetention.checkInRetention] (7 days).
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
    this.status = PendingCheckInQueueStatus.queued,
    this.sessionCodeRaw,
    this.uploadedAt,
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
  final String? sessionCodeRaw;

  /// When this row started waiting (session missing or upload pending).
  final DateTime pendingSince;
  final PendingCheckInQueueStatus status;

  /// When RTD (or client mirror) accepted the upload — cached for Check-ins UI.
  final DateTime? uploadedAt;

  bool get hasLocalUploadEvidence => uploadedAt != null;

  bool get isApproved => status == PendingCheckInQueueStatus.approved;

  PendingCheckInEntry copyWith({
    String? id,
    String? sessionId,
    String? studentId,
    String? listId,
    String? course,
    DateTime? capturedAt,
    double? latitude,
    double? longitude,
    String? deviceId,
    DateTime? pendingSince,
    PendingCheckInQueueStatus? status,
    String? sessionCodeRaw,
    DateTime? uploadedAt,
  }) {
    return PendingCheckInEntry(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      studentId: studentId ?? this.studentId,
      listId: listId ?? this.listId,
      course: course ?? this.course,
      capturedAt: capturedAt ?? this.capturedAt,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      deviceId: deviceId ?? this.deviceId,
      pendingSince: pendingSince ?? this.pendingSince,
      status: status ?? this.status,
      sessionCodeRaw: sessionCodeRaw ?? this.sessionCodeRaw,
      uploadedAt: uploadedAt ?? this.uploadedAt,
    );
  }

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
        'status': status.name,
        if (sessionCodeRaw != null && sessionCodeRaw!.trim().isNotEmpty)
          'sessionCodeRaw': sessionCodeRaw,
        if (uploadedAt != null)
          'uploadedAt': uploadedAt!.toIso8601String(),
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
      final rawStatus = (m['status'] as String?) ?? PendingCheckInQueueStatus.queued.name;
      final status = PendingCheckInQueueStatus.values.firstWhere(
        (e) => e.name == rawStatus,
        orElse: () => PendingCheckInQueueStatus.queued,
      );
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
        status: status,
        sessionCodeRaw: (m['sessionCodeRaw'] as String?)?.trim(),
        uploadedAt: (m['uploadedAt'] as String?) != null
            ? DateTime.tryParse(m['uploadedAt'] as String)
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

class PendingCheckInQueue {
  PendingCheckInQueue._();

  static Future<void>? _writeTail;

  static Future<T> withSerializedWrites<T>(Future<T> Function() body) async {
    final previous = _writeTail;
    final gate = Completer<void>();
    _writeTail = gate.future;
    if (previous != null) {
      await previous;
    }
    try {
      return await body();
    } finally {
      gate.complete();
    }
  }

  static Future<List<PendingCheckInEntry>> mutate(
    Future<List<PendingCheckInEntry>> Function(
      List<PendingCheckInEntry> current,
    ) transform,
  ) {
    return withSerializedWrites(() async {
      final current = await loadAll();
      final next = await transform(List<PendingCheckInEntry>.from(current));
      await _saveAllUnlocked(next);
      return next;
    });
  }

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
    await withSerializedWrites(() => _saveAllUnlocked(items));
  }

  static Future<void> _saveAllUnlocked(List<PendingCheckInEntry> items) async {
    await AttendanceLocalQueues.writeString(
      AttendanceLocalQueues.checkInsJsonKey,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  /// Upsert by [entry.id] (stable per session+student).
  static Future<void> enqueue(PendingCheckInEntry entry) async {
    await mutate((all) async {
      PendingCheckInEntry? existing;
      for (final row in all) {
        if (row.id == entry.id) {
          existing = row;
          break;
        }
      }
      final toWrite = entry.uploadedAt != null
          ? entry
          : (existing?.uploadedAt != null
              ? entry.copyWith(uploadedAt: existing!.uploadedAt)
              : entry);
      all.removeWhere((e) => e.id == entry.id);
      all.add(toWrite);
      return all;
    });
    notifyPendingWorkEnqueued();
  }

  static Future<void> removeById(String id) async {
    await mutate((all) async {
      all.removeWhere((e) => e.id == id);
      return all;
    });
    notifyPendingWorkQueuesChanged();
  }

  static Future<void> removeBySessionId(String sessionId) async {
    final sid = sessionId.trim();
    if (sid.isEmpty) return;
    await mutate((all) async {
      all.removeWhere((e) => e.sessionId == sid);
      return all;
    });
    notifyPendingWorkQueuesChanged();
  }

  /// Caches that upload evidence reached RTD (survives Firestore read denials).
  static Future<void> markUploaded(String id, {DateTime? at}) async {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return;
    final stamp = at ?? DateTime.now();
    var changed = false;
    await mutate((all) async {
      for (var i = 0; i < all.length; i++) {
        if (all[i].id != trimmed) continue;
        if (all[i].uploadedAt != null) return all;
        all[i] = all[i].copyWith(uploadedAt: stamp);
        changed = true;
        break;
      }
      return all;
    });
    if (changed) {
      notifyPendingWorkQueuesChanged();
    }
  }

  /// Marks a row approved but keeps it for [PendingRetention.checkInRetention].
  static Future<void> markApproved(String id) async {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return;
    var changed = false;
    await mutate((all) async {
      for (var i = 0; i < all.length; i++) {
        if (all[i].id != trimmed) continue;
        all[i] = all[i].copyWith(status: PendingCheckInQueueStatus.approved);
        changed = true;
        break;
      }
      return all;
    });
    if (changed) {
      notifyPendingWorkQueuesChanged();
    }
  }

  static Future<void> clear() async {
    await AttendanceLocalQueues.removeKey(AttendanceLocalQueues.checkInsJsonKey);
  }
}
