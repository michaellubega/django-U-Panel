import 'dart:convert';

import '../../../core/notifications/pending_work_notification_hooks.dart';
import '../../../core/storage/attendance_local_queues.dart';
import '../../../core/storage/local_json_decode.dart';
import '../campus_presence_grouping.dart';
import '../models/campus_presence_models.dart';
import '../../attendance/data/pending_retention.dart';

const _maxEntries = 64;

/// Locally queued KIU administrator campus arrival / departure.
class PendingCampusPresenceEntry {
  PendingCampusPresenceEntry({
    required this.id,
    required this.adminUid,
    required this.kind,
    required this.capturedAt,
    required this.localDateKey,
    required this.latitude,
    required this.longitude,
    required this.deviceId,
    this.displayName,
    this.adminEmail,
    this.staffNumber,
    this.jobTitle,
    DateTime? pendingSince,
  }) : pendingSince = pendingSince ?? capturedAt;

  final String id;
  final String adminUid;
  final CampusPresenceKind kind;
  final DateTime capturedAt;
  final String localDateKey;
  final double latitude;
  final double longitude;
  final String deviceId;
  final String? displayName;
  final String? adminEmail;
  final String? staffNumber;
  final String? jobTitle;
  final DateTime pendingSince;

  CampusPresenceEvent toEvent() => CampusPresenceEvent(
        id: id,
        adminUid: adminUid,
        kind: kind,
        capturedAt: capturedAt,
        localDateKey: localDateKey,
        latitude: latitude,
        longitude: longitude,
        displayName: displayName,
        adminEmail: adminEmail,
        staffNumber: staffNumber,
        jobTitle: jobTitle,
        deviceId: deviceId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'adminUid': adminUid,
        'kind': kind.firestoreValue,
        'capturedAt': capturedAt.toIso8601String(),
        'localDateKey': localDateKey,
        'latitude': latitude,
        'longitude': longitude,
        'deviceId': deviceId,
        if (displayName != null && displayName!.isNotEmpty)
          'displayName': displayName,
        if (adminEmail != null && adminEmail!.isNotEmpty) 'adminEmail': adminEmail,
        if (staffNumber != null && staffNumber!.isNotEmpty)
          'staffNumber': staffNumber,
        if (jobTitle != null && jobTitle!.isNotEmpty) 'jobTitle': jobTitle,
        'pendingSince': pendingSince.toIso8601String(),
      };

  static PendingCampusPresenceEntry? fromJson(Map<String, dynamic> m) {
    try {
      final id = m['id'] as String?;
      final adminUid = m['adminUid'] as String?;
      final kind = CampusPresenceKindX.parse(m['kind'] as String?);
      final cap = m['capturedAt'] as String?;
      final dateKey = m['localDateKey'] as String?;
      final lat = (m['latitude'] as num?)?.toDouble();
      final lng = (m['longitude'] as num?)?.toDouble();
      final deviceId = m['deviceId'] as String?;
      if (id == null ||
          adminUid == null ||
          kind == null ||
          cap == null ||
          dateKey == null ||
          lat == null ||
          lng == null ||
          deviceId == null) {
        return null;
      }
      final captured = DateTime.parse(cap);
      final sinceRaw = m['pendingSince'] as String?;
      final since = sinceRaw != null ? DateTime.tryParse(sinceRaw) : null;
      return PendingCampusPresenceEntry(
        id: id,
        adminUid: adminUid,
        kind: kind,
        capturedAt: captured,
        localDateKey: dateKey,
        latitude: lat,
        longitude: lng,
        deviceId: deviceId,
        displayName: (m['displayName'] as String?)?.trim(),
        adminEmail: (m['adminEmail'] as String?)?.trim(),
        staffNumber: (m['staffNumber'] as String?)?.trim(),
        jobTitle: (m['jobTitle'] as String?)?.trim(),
        pendingSince: PendingRetention.pendingSinceOr(captured, since),
      );
    } catch (_) {
      return null;
    }
  }
}

class PendingCampusPresenceQueue {
  PendingCampusPresenceQueue._();

  static Future<List<PendingCampusPresenceEntry>> loadAll() async {
    final raw = await AttendanceLocalQueues.readString(
      AttendanceLocalQueues.campusPresenceJsonKey,
    );
    if (raw == null || raw.isEmpty) return [];
    final list = await decodeStoredJson<List<dynamic>>(
      raw: raw,
      storageKey: AttendanceLocalQueues.campusPresenceJsonKey,
      removeKey: AttendanceLocalQueues.removeKey,
      parse: (decoded) => decoded is List ? decoded : const <dynamic>[],
      debugLabel: 'PendingCampusPresenceQueue',
    );
    if (list == null || list.isEmpty) return [];
    final out = <PendingCampusPresenceEntry>[];
    for (final e in list) {
      if (e is! Map) continue;
      final ent = PendingCampusPresenceEntry.fromJson(
        Map<String, dynamic>.from(e),
      );
      if (ent != null) out.add(ent);
    }
    return out;
  }

  static Future<void> saveAll(List<PendingCampusPresenceEntry> items) async {
    final trimmed = items.length > _maxEntries
        ? items.sublist(items.length - _maxEntries)
        : items;
    await AttendanceLocalQueues.writeString(
      AttendanceLocalQueues.campusPresenceJsonKey,
      jsonEncode(trimmed.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> enqueue(PendingCampusPresenceEntry entry) async {
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

  static Future<List<CampusPresenceEvent>> eventsForAdminDate({
    required String adminUid,
    required String localDateKey,
  }) async {
    final uid = adminUid.trim();
    final key = localDateKey.trim();
    if (uid.isEmpty || key.isEmpty) return const [];
    final all = await loadAll();
    return [
      for (final e in all)
        if (e.adminUid == uid && e.localDateKey == key) e.toEvent(),
    ]..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
  }

  static Future<int> pendingCountForAdmin(String adminUid) async {
    final uid = adminUid.trim();
    if (uid.isEmpty) return 0;
    final all = await loadAll();
    return all.where((e) => e.adminUid == uid).length;
  }

  static PendingCampusPresenceEntry build({
    required String adminUid,
    required CampusPresenceKind kind,
    required DateTime capturedAt,
    required String localDateKey,
    required double latitude,
    required double longitude,
    required String deviceId,
    String? displayName,
    String? adminEmail,
    String? staffNumber,
    String? jobTitle,
  }) {
    final id = campusPresenceDocId(
      adminUid: adminUid,
      localDateKey: localDateKey,
      kind: kind,
    );
    return PendingCampusPresenceEntry(
      id: id,
      adminUid: adminUid,
      kind: kind,
      capturedAt: capturedAt,
      localDateKey: localDateKey,
      latitude: latitude,
      longitude: longitude,
      deviceId: deviceId,
      displayName: displayName,
      adminEmail: adminEmail,
      staffNumber: staffNumber,
      jobTitle: jobTitle,
    );
  }
}
