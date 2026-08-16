import 'dart:convert';

import '../../../core/notifications/pending_work_notification_hooks.dart';
import '../../../core/storage/attendance_local_queues.dart';
import '../../../core/storage/local_json_decode.dart';
import '../models/attendance_models.dart';

const _maxEntries = 100;
const _storageKey = 'pending_attendance_list_creates';

/// Attendance list created offline — upload to Firestore when online.
class PendingListCreateEntry {
  PendingListCreateEntry({
    required this.list,
    required this.enqueuedAt,
    this.pendingLecturerStaffNumber,
  });

  final AttendanceList list;
  final DateTime enqueuedAt;

  /// When offline, lecturer uid may be resolved at upload time.
  final String? pendingLecturerStaffNumber;

  Map<String, dynamic> toJson() => {
        'list': _listToJson(list),
        'enqueuedAt': enqueuedAt.toIso8601String(),
        if (pendingLecturerStaffNumber != null &&
            pendingLecturerStaffNumber!.trim().isNotEmpty)
          'pendingLecturerStaffNumber': pendingLecturerStaffNumber!.trim(),
      };

  static PendingListCreateEntry? fromJson(Map<String, dynamic> m) {
    try {
      final listRaw = m['list'];
      final enqRaw = m['enqueuedAt'] as String?;
      if (listRaw is! Map || enqRaw == null) return null;
      final enq = DateTime.tryParse(enqRaw);
      if (enq == null) return null;
      final list = _listFromJson(Map<String, dynamic>.from(listRaw));
      if (list.id.isEmpty) return null;
      final pendingStaff =
          (m['pendingLecturerStaffNumber'] as String?)?.trim();
      return PendingListCreateEntry(
        list: list,
        enqueuedAt: enq,
        pendingLecturerStaffNumber:
            pendingStaff == null || pendingStaff.isEmpty ? null : pendingStaff,
      );
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _listToJson(AttendanceList l) => {
        'id': l.id,
        'time': l.time,
        'room': l.room,
        'whoTaught': l.whoTaught,
        'dateMs': l.date.millisecondsSinceEpoch,
        'program': l.program.name,
        'courses': l.coursesSafe,
        'year': l.year,
        'sem': l.sem,
        'createdBy': l.createdBy,
        'lecturerUid': l.lecturerUid,
        'expectedParticipants': l.expectedParticipants,
        'status': l.status.name,
        'lecturerSignCode': l.lecturerSignCode,
        'lecturerSignedAtMs': l.lecturerSignedAt?.millisecondsSinceEpoch,
        'courseUnitName': l.courseUnitName,
      };

  static AttendanceList _listFromJson(Map<String, dynamic> m) {
    final dateMs = (m['dateMs'] as num?)?.toInt();
    AttendanceListStatus status = AttendanceListStatus.draft;
    final statusRaw = m['status'] as String?;
    if (statusRaw == 'active') {
      status = AttendanceListStatus.active;
    } else if (statusRaw == 'closed') {
      status = AttendanceListStatus.closed;
    }
    return AttendanceList(
      id: m['id'] as String? ?? '',
      time: m['time'] as String? ?? '',
      room: m['room'] as String? ?? '',
      whoTaught: m['whoTaught'] as String? ?? '',
      date: dateMs != null
          ? attendanceListDateFromStored(dateMs)
          : attendanceListDateForWeekday(
              DateTime.now().toLocal().weekday.clamp(1, 7),
            ),
      program: AttendanceProgram.fromStorage(m['program'] as String?),
      courses: (m['courses'] as List<dynamic>?)?.cast<String>(),
      year: m['year'] as String? ?? '1',
      sem: m['sem'] as String? ?? '1',
      createdBy: m['createdBy'] as String?,
      lecturerUid: (m['lecturerUid'] as String?)?.trim(),
      expectedParticipants: (m['expectedParticipants'] as num?)?.toInt(),
      status: status,
      lecturerSignCode: (m['lecturerSignCode'] as String?)?.trim().isEmpty == true
          ? null
          : m['lecturerSignCode'] as String?,
      lecturerSignedAt: (m['lecturerSignedAtMs'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (m['lecturerSignedAtMs'] as num).toInt(),
            )
          : null,
      courseUnitName: (m['courseUnitName'] as String?)?.trim().isEmpty == true
          ? null
          : (m['courseUnitName'] as String?)?.trim(),
    );
  }
}

class PendingListCreateQueue {
  PendingListCreateQueue._();

  static Future<List<PendingListCreateEntry>> loadAll() async {
    final raw = await AttendanceLocalQueues.readString(_storageKey);
    if (raw == null || raw.isEmpty) return [];
    final list = await decodeStoredJson<List<dynamic>>(
      raw: raw,
      storageKey: _storageKey,
      removeKey: AttendanceLocalQueues.removeKey,
      parse: (decoded) => decoded is List ? decoded : const <dynamic>[],
      debugLabel: 'PendingListCreateQueue',
    );
    if (list == null || list.isEmpty) return [];
    final out = <PendingListCreateEntry>[];
    for (final e in list) {
      if (e is! Map) continue;
      final ent =
          PendingListCreateEntry.fromJson(Map<String, dynamic>.from(e));
      if (ent != null) out.add(ent);
    }
    return out;
  }

  static Future<void> saveAll(List<PendingListCreateEntry> items) async {
    final trimmed = items.length > _maxEntries
        ? items.sublist(items.length - _maxEntries)
        : items;
    await AttendanceLocalQueues.writeString(
      _storageKey,
      jsonEncode(trimmed.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> enqueue(
    AttendanceList list, {
    String? pendingLecturerStaffNumber,
  }) async {
    final all = await loadAll();
    all.removeWhere((e) => e.list.id == list.id);
    all.add(
      PendingListCreateEntry(
        list: list,
        enqueuedAt: DateTime.now(),
        pendingLecturerStaffNumber: pendingLecturerStaffNumber,
      ),
    );
    await saveAll(all);
    notifyPendingWorkEnqueued();
  }

  static Future<void> removeByListId(String listId) async {
    final all = await loadAll();
    all.removeWhere((e) => e.list.id == listId);
    await saveAll(all);
    notifyPendingWorkQueuesChanged();
  }

  /// Ensures offline-created lists stay visible after [loadAll] replaces the store.
  static Future<void> rehydrateIntoStore() async {
    final pending = await loadAll();
    for (final e in pending) {
      final existing = AttendanceStore.listById(e.list.id);
      if (existing == null) {
        AttendanceStore.addList(e.list);
      } else {
        AttendanceStore.updateList(e.list);
      }
    }
  }
}
