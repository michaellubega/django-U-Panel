import 'dart:async';
import 'dart:convert';

import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/device/device_student_registration_lock.dart';
import '../../../core/notifications/pending_work_notification_hooks.dart';
import '../../../core/storage/attendance_local_queues.dart';
import '../../../core/storage/local_json_decode.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';
import 'pending_retention.dart';
import 'pending_session_code_claim_upload.dart';
import 'pending_session_code_sync.dart';

enum PendingSessionCodeStatus {
  queued,
  approved,
  needsRegistration,
  invalidOrExpired,
  deviceBlocked,
  /// Upload attempted but failed (network error / server rejection).
  /// The user sees an actionable message; next drain will retry automatically.
  uploadFailed,
}

class PendingSessionCodeEntry {
  PendingSessionCodeEntry({
    required this.id,
    required this.registrationNumber,
    required this.sessionCodeRaw,
    required this.capturedAt,
    required this.latitude,
    required this.longitude,
    required this.deviceId,
    this.sessionId,
    this.listId,
    this.lecturerName,
    this.classTime,
    this.classLocation,
    this.status = PendingSessionCodeStatus.queued,
    this.note,
    this.invalidMarkedAt,
    DateTime? pendingSince,
    this.uploadedAt,
    this.retryCount = 0,
  }) : pendingSince = PendingRetention.pendingSinceOr(capturedAt, pendingSince);

  /// When waiting for session verification (or upload).
  final DateTime pendingSince;

  final String id;
  final String registrationNumber;
  final String sessionCodeRaw;
  final DateTime capturedAt;
  final double latitude;
  final double longitude;
  final String deviceId;

  final String? sessionId;
  final String? listId;
  final String? lecturerName;
  final String? classTime;
  final String? classLocation;
  final PendingSessionCodeStatus status;
  final String? note;
  final DateTime? invalidMarkedAt;
  final DateTime? uploadedAt;

  /// Number of consecutive drain attempts that ended in a transient failure.
  /// Used to decide when to surface an error to the user.
  final int retryCount;

  bool get hasLocalUploadEvidence => uploadedAt != null;

  PendingSessionCodeEntry copyWith({
    String? sessionId,
    String? listId,
    String? lecturerName,
    String? classTime,
    String? classLocation,
    PendingSessionCodeStatus? status,
    String? note,
    DateTime? invalidMarkedAt,
    DateTime? pendingSince,
    DateTime? uploadedAt,
    int? retryCount,
  }) {
    return PendingSessionCodeEntry(
      id: id,
      registrationNumber: registrationNumber,
      sessionCodeRaw: sessionCodeRaw,
      capturedAt: capturedAt,
      latitude: latitude,
      longitude: longitude,
      deviceId: deviceId,
      sessionId: sessionId ?? this.sessionId,
      listId: listId ?? this.listId,
      lecturerName: lecturerName ?? this.lecturerName,
      classTime: classTime ?? this.classTime,
      classLocation: classLocation ?? this.classLocation,
      status: status ?? this.status,
      note: note ?? this.note,
      invalidMarkedAt: invalidMarkedAt ?? this.invalidMarkedAt,
      pendingSince: pendingSince ?? this.pendingSince,
      uploadedAt: uploadedAt ?? this.uploadedAt,
      retryCount: retryCount ?? this.retryCount,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'registrationNumber': registrationNumber,
        'sessionCodeRaw': sessionCodeRaw,
        'capturedAt': capturedAt.toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        'deviceId': deviceId,
        'sessionId': sessionId,
        'listId': listId,
        'lecturerName': lecturerName,
        'classTime': classTime,
        'classLocation': classLocation,
        'status': status.name,
        'note': note,
        'invalidMarkedAt': invalidMarkedAt?.toIso8601String(),
        'pendingSince': pendingSince.toIso8601String(),
        if (uploadedAt != null) 'uploadedAt': uploadedAt!.toIso8601String(),
        if (retryCount > 0) 'retryCount': retryCount,
      };

  static PendingSessionCodeEntry? fromJson(Map<String, dynamic> m) {
    try {
      final id = m['id'] as String?;
      final reg = m['registrationNumber'] as String?;
      final code = m['sessionCodeRaw'] as String?;
      final cap = m['capturedAt'] as String?;
      final lat = (m['latitude'] as num?)?.toDouble();
      final lng = (m['longitude'] as num?)?.toDouble();
      final deviceId = m['deviceId'] as String?;
      if (id == null ||
          reg == null ||
          code == null ||
          cap == null ||
          lat == null ||
          lng == null ||
          deviceId == null) {
        return null;
      }
      final rawStatus = (m['status'] as String?) ?? PendingSessionCodeStatus.queued.name;
      final status = PendingSessionCodeStatus.values.firstWhere(
        (e) => e.name == rawStatus,
        orElse: () => PendingSessionCodeStatus.queued,
      );
      final captured = DateTime.parse(cap);
      final sinceRaw = m['pendingSince'] as String?;
      final since = sinceRaw != null
          ? DateTime.tryParse(sinceRaw)
          : null;
      return PendingSessionCodeEntry(
        id: id,
        registrationNumber: reg,
        sessionCodeRaw: code,
        capturedAt: captured,
        latitude: lat,
        longitude: lng,
        deviceId: deviceId,
        sessionId: m['sessionId'] as String?,
        listId: m['listId'] as String?,
        lecturerName: m['lecturerName'] as String?,
        classTime: m['classTime'] as String?,
        classLocation: m['classLocation'] as String?,
        status: status,
        note: m['note'] as String?,
        invalidMarkedAt: (m['invalidMarkedAt'] as String?) != null
            ? DateTime.tryParse(m['invalidMarkedAt'] as String)
            : null,
        pendingSince: PendingRetention.pendingSinceOr(captured, since),
        uploadedAt: (m['uploadedAt'] as String?) != null
            ? DateTime.tryParse(m['uploadedAt'] as String)
            : null,
        retryCount: (m['retryCount'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

class PendingSessionSyncResult {
  const PendingSessionSyncResult({
    required this.ranAt,
    required this.startedCount,
    required this.remainingCount,
    required this.autoSubmittedCount,
    required this.needsRegistrationCount,
    required this.invalidMarkedCount,
    required this.invalidRemovedCount,
    required this.deviceBlockedCount,
  });

  final DateTime ranAt;
  final int startedCount;
  final int remainingCount;
  final int autoSubmittedCount;
  final int needsRegistrationCount;
  final int invalidMarkedCount;
  final int invalidRemovedCount;
  final int deviceBlockedCount;

  Map<String, dynamic> toJson() => {
        'ranAt': ranAt.toIso8601String(),
        'startedCount': startedCount,
        'remainingCount': remainingCount,
        'autoSubmittedCount': autoSubmittedCount,
        'needsRegistrationCount': needsRegistrationCount,
        'invalidMarkedCount': invalidMarkedCount,
        'invalidRemovedCount': invalidRemovedCount,
        'deviceBlockedCount': deviceBlockedCount,
      };

  static PendingSessionSyncResult? fromJson(Map<String, dynamic> m) {
    try {
      final ranAtRaw = m['ranAt'] as String?;
      if (ranAtRaw == null) return null;
      final ranAt = DateTime.tryParse(ranAtRaw);
      if (ranAt == null) return null;
      return PendingSessionSyncResult(
        ranAt: ranAt,
        startedCount: (m['startedCount'] as num?)?.toInt() ?? 0,
        remainingCount: (m['remainingCount'] as num?)?.toInt() ?? 0,
        autoSubmittedCount: (m['autoSubmittedCount'] as num?)?.toInt() ?? 0,
        needsRegistrationCount:
            (m['needsRegistrationCount'] as num?)?.toInt() ?? 0,
        invalidMarkedCount: (m['invalidMarkedCount'] as num?)?.toInt() ?? 0,
        invalidRemovedCount: (m['invalidRemovedCount'] as num?)?.toInt() ?? 0,
        deviceBlockedCount: (m['deviceBlockedCount'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

class PendingSessionCodeQueue {
  PendingSessionCodeQueue._();

  static Future<void>? _writeTail;

  /// Serializes read-modify-write so enqueue and drain cannot clobber each other.
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

  /// Atomically loads, transforms, and saves the queue.
  static Future<List<PendingSessionCodeEntry>> mutate(
    Future<List<PendingSessionCodeEntry>> Function(
      List<PendingSessionCodeEntry> current,
    ) transform,
  ) {
    return withSerializedWrites(() async {
      final current = await loadAll();
      final next = await transform(List<PendingSessionCodeEntry>.from(current));
      await _saveAllUnlocked(next);
      return next;
    });
  }

  static Future<List<PendingSessionCodeEntry>> loadAll() async {
    final raw = await AttendanceLocalQueues.readString(
      AttendanceLocalQueues.sessionCodesJsonKey,
    );
    if (raw == null || raw.isEmpty) return [];
    final list = await decodeStoredJson<List<dynamic>>(
      raw: raw,
      storageKey: AttendanceLocalQueues.sessionCodesJsonKey,
      removeKey: AttendanceLocalQueues.removeKey,
      parse: (decoded) => decoded is List ? decoded : const <dynamic>[],
      debugLabel: 'PendingSessionCodeQueue',
    );
    if (list == null || list.isEmpty) return [];
    final out = <PendingSessionCodeEntry>[];
    for (final e in list) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final ent = PendingSessionCodeEntry.fromJson(m);
      if (ent != null) out.add(ent);
    }
    return out;
  }

  static Future<void> saveAll(List<PendingSessionCodeEntry> items) async {
    await withSerializedWrites(() => _saveAllUnlocked(items));
  }

  static Future<void> _saveAllUnlocked(List<PendingSessionCodeEntry> items) async {
    await AttendanceLocalQueues.writeString(
      AttendanceLocalQueues.sessionCodesJsonKey,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> enqueue(PendingSessionCodeEntry entry) async {
    var toSave = entry;
    if (AttendanceRepository.shouldEnforceDeviceStudentRegistrationLock()) {
      final regBlock =
          await DeviceStudentRegistrationLock.blockReasonFor(
        entry.registrationNumber,
      );
      if (regBlock != null) {
        toSave = entry.copyWith(
          status: PendingSessionCodeStatus.deviceBlocked,
          note: regBlock,
        );
        await _persistEntry(toSave);
        return;
      }
    }
    final localBlock =
        await PendingSessionCodeClaimUpload.localDeviceBlockReason(entry);
    if (localBlock != null) {
      toSave = entry.copyWith(
        status: PendingSessionCodeStatus.deviceBlocked,
        note: localBlock,
      );
      await _persistEntry(toSave);
      return;
    }

    await _persistEntry(toSave);
    if (toSave.status != PendingSessionCodeStatus.deviceBlocked &&
        AttendanceRepository.shouldEnforceDeviceStudentRegistrationLock()) {
      unawaited(
        DeviceStudentRegistrationLock.bindRegistration(
          toSave.registrationNumber,
        ),
      );
    }
    notifyPendingWorkEnqueued();
    if (AppConnectivity.instance.hasNetworkInterface &&
        toSave.status != PendingSessionCodeStatus.deviceBlocked) {
      PendingSessionCodeSync.ensureWatchingSessionPublishForCodes(
        [toSave.sessionCodeRaw],
      );
      unawaited(_uploadMetadataAfterEnqueue(toSave));
    }
  }

  /// Persists the queue row first, then uploads metadata / verifies in background.
  static Future<void> _uploadMetadataAfterEnqueue(
    PendingSessionCodeEntry entry,
  ) async {
    try {
      final processed = await PendingSessionCodeSync.processOnCreate(entry);
      if (processed.discardLocal) {
        await removeById(entry.id);
        notifyPendingWorkQueuesChanged();
        AttendanceRepository.instance.notifyAttendanceStoreUpdated();
        return;
      }
      if (processed.keepLocal != null && processed.keepLocal!.id == entry.id) {
        final updated = processed.keepLocal!;
        if (updated != entry) {
          await _persistEntry(updated);
        }
      }
    } catch (_) {}
    if (!PendingSessionCodeSync.isDraining) {
      unawaited(PendingSessionCodeSync.drainUrgent());
    }
  }

  /// Persists without scheduling upload/drain — use during an active drain pass.
  static Future<void> updateStoredEntry(PendingSessionCodeEntry entry) async {
    await _persistEntry(entry);
    notifyPendingWorkQueuesChanged();
  }

  static PendingSessionCodeEntry _withPreservedUploadAt(
    PendingSessionCodeEntry incoming,
    PendingSessionCodeEntry? existing,
  ) {
    if (incoming.uploadedAt != null) return incoming;
    final prior = existing?.uploadedAt;
    if (prior == null) return incoming;
    return incoming.copyWith(uploadedAt: prior);
  }

  static Future<void> _persistEntry(PendingSessionCodeEntry entry) async {
    await mutate((all) async {
      PendingSessionCodeEntry? existing;
      for (final row in all) {
        if (row.id == entry.id) {
          existing = row;
          break;
        }
      }
      final toWrite = _withPreservedUploadAt(entry, existing);
      all.removeWhere((e) => e.id == entry.id);
      all.add(toWrite);
      return all;
    });
  }

  static Future<void> removeById(String id) async {
    await mutate((all) async {
      all.removeWhere((e) => e.id == id);
      return all;
    });
    notifyPendingWorkQueuesChanged();
  }

  static Future<void> removeForSession({
    required String sessionId,
    required String sessionCodeRaw,
  }) async {
    final sid = sessionId.trim();
    final code = normalizeSessionCodeInput(sessionCodeRaw);
    await mutate((all) async {
      all.removeWhere((e) {
        if (sid.isNotEmpty && e.sessionId?.trim() == sid) return true;
        if (code.isNotEmpty &&
            normalizeSessionCodeInput(e.sessionCodeRaw) == code) {
          return true;
        }
        return false;
      });
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

  static Future<void> saveLastSyncResult(PendingSessionSyncResult result) async {
    await AttendanceLocalQueues.writeString(
      AttendanceLocalQueues.sessionSyncSummaryJsonKey,
      jsonEncode(result.toJson()),
    );
  }

  static Future<PendingSessionSyncResult?> loadLastSyncResult() async {
    final raw = await AttendanceLocalQueues.readString(
      AttendanceLocalQueues.sessionSyncSummaryJsonKey,
    );
    if (raw == null || raw.isEmpty) return null;
    final decoded = await decodeStoredJson<Map<String, dynamic>>(
      raw: raw,
      storageKey: AttendanceLocalQueues.sessionSyncSummaryJsonKey,
      removeKey: AttendanceLocalQueues.removeKey,
      parse: (value) =>
          value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{},
      debugLabel: 'PendingSessionCodeQueue.syncSummary',
    );
    if (decoded == null || decoded.isEmpty) return null;
    return PendingSessionSyncResult.fromJson(decoded);
  }
}

