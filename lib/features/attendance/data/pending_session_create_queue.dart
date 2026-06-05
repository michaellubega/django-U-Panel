import 'dart:convert';

import '../../../core/storage/attendance_local_queues.dart';

const _maxEntries = 50;

/// Lecturer session started offline — upload to Firestore when online.
class PendingSessionCreateEntry {
  PendingSessionCreateEntry({
    required this.sessionId,
    required this.listId,
    required this.sessionCode,
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
    required this.startTime,
    required this.endTime,
    required this.createdBy,
    required this.enqueuedAt,
    this.remoteLearning = false,
  });

  final String sessionId;
  final String listId;
  final String sessionCode;
  final double latitude;
  final double longitude;
  final double radiusMeters;
  final DateTime startTime;
  final DateTime endTime;
  final String createdBy;
  final DateTime enqueuedAt;
  final bool remoteLearning;

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'listId': listId,
        'sessionCode': sessionCode,
        'latitude': latitude,
        'longitude': longitude,
        'radiusMeters': radiusMeters,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'createdBy': createdBy,
        'enqueuedAt': enqueuedAt.toIso8601String(),
        if (remoteLearning) 'remoteLearning': true,
      };

  static PendingSessionCreateEntry? fromJson(Map<String, dynamic> m) {
    try {
      final sessionId = m['sessionId'] as String?;
      final listId = m['listId'] as String?;
      final code = m['sessionCode'] as String?;
      final createdBy = m['createdBy'] as String?;
      final startRaw = m['startTime'] as String?;
      final endRaw = m['endTime'] as String?;
      final enqRaw = m['enqueuedAt'] as String?;
      final lat = (m['latitude'] as num?)?.toDouble();
      final lng = (m['longitude'] as num?)?.toDouble();
      final radius = (m['radiusMeters'] as num?)?.toDouble();
      if (sessionId == null ||
          listId == null ||
          code == null ||
          createdBy == null ||
          startRaw == null ||
          endRaw == null ||
          enqRaw == null ||
          lat == null ||
          lng == null ||
          radius == null) {
        return null;
      }
      final start = DateTime.tryParse(startRaw);
      final end = DateTime.tryParse(endRaw);
      final enq = DateTime.tryParse(enqRaw);
      if (start == null || end == null || enq == null) return null;
      return PendingSessionCreateEntry(
        sessionId: sessionId,
        listId: listId,
        sessionCode: code,
        latitude: lat,
        longitude: lng,
        radiusMeters: radius,
        startTime: start,
        endTime: end,
        createdBy: createdBy,
        enqueuedAt: enq,
        remoteLearning: m['remoteLearning'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

class PendingSessionCreateQueue {
  PendingSessionCreateQueue._();

  static const _storageKey = 'pending_attendance_session_creates';

  static Future<List<PendingSessionCreateEntry>> loadAll() async {
    final raw = await AttendanceLocalQueues.readString(_storageKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final out = <PendingSessionCreateEntry>[];
      for (final e in list) {
        if (e is! Map) continue;
        final ent =
            PendingSessionCreateEntry.fromJson(Map<String, dynamic>.from(e));
        if (ent != null) out.add(ent);
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveAll(List<PendingSessionCreateEntry> items) async {
    final trimmed = items.length > _maxEntries
        ? items.sublist(items.length - _maxEntries)
        : items;
    await AttendanceLocalQueues.writeString(
      _storageKey,
      jsonEncode(trimmed.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> enqueue(PendingSessionCreateEntry entry) async {
    final all = await loadAll();
    all.removeWhere((e) => e.sessionId == entry.sessionId);
    all.add(entry);
    await saveAll(all);
  }

  static Future<void> removeBySessionId(String sessionId) async {
    final all = await loadAll();
    all.removeWhere((e) => e.sessionId == sessionId);
    await saveAll(all);
  }
}
