import 'dart:convert';

import '../../core/auth/staff_auth_email.dart';
import 'attendance_local_queues.dart';
import 'local_json_decode.dart';

const _storageKey = 'staff_number_directory_v1';

/// Local staff-number → Firebase uid map for offline lecturer assignment.
class StaffNumberDirectoryCache {
  StaffNumberDirectoryCache._();

  static Future<Map<String, String>> _loadMap() async {
    final raw = await AttendanceLocalQueues.readString(_storageKey);
    if (raw == null || raw.isEmpty) return {};
    final decoded = await decodeStoredJson<Map<String, dynamic>>(
      raw: raw,
      storageKey: _storageKey,
      removeKey: AttendanceLocalQueues.removeKey,
      parse: (value) => value is Map ? Map<String, dynamic>.from(value) : {},
      debugLabel: 'StaffNumberDirectoryCache',
    );
    if (decoded == null || decoded.isEmpty) return {};
    final out = <String, String>{};
    for (final entry in decoded.entries) {
      final sn = entry.key.trim().toUpperCase();
      final uid = (entry.value as String?)?.trim();
      if (sn.isEmpty || uid == null || uid.isEmpty) continue;
      out[sn] = uid;
    }
    return out;
  }

  static Future<void> remember(String staffNumber, String uid) async {
    final sn = StaffAuthEmail.normalizeStaffNumberFlexible(staffNumber);
    final u = uid.trim();
    if (sn == null || u.isEmpty) return;
    final map = await _loadMap();
    if (map[sn] == u) return;
    map[sn] = u;
    await AttendanceLocalQueues.writeString(_storageKey, jsonEncode(map));
  }

  static Future<String?> lookup(String staffNumber) async {
    final sn = StaffAuthEmail.normalizeStaffNumberFlexible(staffNumber);
    if (sn == null) return null;
    final map = await _loadMap();
    return map[sn];
  }

  static Future<List<({String uid, String staffNumber})>> knownRows() async {
    final map = await _loadMap();
    return [
      for (final entry in map.entries)
        (uid: entry.value, staffNumber: entry.key),
    ];
  }
}
