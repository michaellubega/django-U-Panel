import 'dart:convert';

import '../../features/attendance/models/attendance_models.dart';
import '../storage/attendance_local_queues.dart';
import '../storage/local_json_decode.dart';

/// Persists which student used this install for a session so proxy check-in
/// stays blocked after sign-out on a shared phone.
class DeviceSessionUsageStore {
  DeviceSessionUsageStore._();

  static const _hiveKey = 'device_session_usage_v1';
  static const _version = 1;
  static const _maxEntries = 240;

  static Future<Map<String, Map<String, dynamic>>> _loadEntries() async {
    final raw = await AttendanceLocalQueues.readString(_hiveKey);
    if (raw == null || raw.isEmpty) return {};
    final decoded = await decodeStoredJson<Map<String, dynamic>>(
      raw: raw,
      storageKey: _hiveKey,
      removeKey: AttendanceLocalQueues.removeKey,
      parse: (value) =>
          value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{},
      debugLabel: 'DeviceSessionUsageStore',
    );
    if (decoded == null || decoded.isEmpty) return {};
    if ((decoded['v'] as num?)?.toInt() != _version) return {};
    final entries = decoded['entries'];
    if (entries is! Map) return {};
    return entries.map(
      (key, value) => MapEntry(
        key.toString(),
        value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{},
      ),
    );
  }

  static Future<void> _saveEntries(Map<String, Map<String, dynamic>> entries) async {
    if (entries.isEmpty) {
      await AttendanceLocalQueues.removeKey(_hiveKey);
      return;
    }
    var trimmed = entries;
    if (entries.length > _maxEntries) {
      final sorted = entries.entries.toList()
        ..sort((a, b) {
          final at = DateTime.tryParse(a.value['at'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final bt = DateTime.tryParse(b.value['at'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
          return at.compareTo(bt);
        });
      trimmed = Map.fromEntries(sorted.skip(sorted.length - _maxEntries));
    }
    await AttendanceLocalQueues.writeString(
      _hiveKey,
      jsonEncode(<String, dynamic>{
        'v': _version,
        'entries': trimmed,
      }),
    );
  }

  static String _entryKey({
    required String sessionId,
    required String sessionCode,
  }) {
    final sid = sessionId.trim();
    if (sid.isNotEmpty) return 'sid:$sid';
    final code = normalizeSessionCodeInput(sessionCode);
    if (code.isNotEmpty && isValidJoinCodeFormat(code)) {
      return 'code:$code';
    }
    return '';
  }

  static Future<void> recordPresentCheckIn({
    required String deviceId,
    required String studentId,
    required String sessionId,
    String? sessionCode,
  }) async {
    final dev = deviceId.trim();
    final stu = studentId.trim();
    if (dev.isEmpty || stu.isEmpty) return;
    final key = _entryKey(
      sessionId: sessionId,
      sessionCode: sessionCode ?? '',
    );
    if (key.isEmpty) return;
    final entries = await _loadEntries();
    entries[key] = <String, dynamic>{
      'deviceId': dev,
      'studentId': stu,
      'at': DateTime.now().toUtc().toIso8601String(),
    };
    await _saveEntries(entries);
  }

  static Future<bool> isBlockedForOtherStudent({
    required String deviceId,
    required String studentId,
    required String sessionId,
    String? sessionCode,
  }) async {
    final dev = deviceId.trim();
    final stu = studentId.trim();
    if (dev.isEmpty || stu.isEmpty) return false;
    final entries = await _loadEntries();
    final key = _entryKey(
      sessionId: sessionId,
      sessionCode: sessionCode ?? '',
    );
    if (key.isEmpty) return false;
    final entry = entries[key];
    if (entry == null || entry.isEmpty) return false;
    final otherDev = (entry['deviceId'] as String?)?.trim() ?? '';
    final otherStu = (entry['studentId'] as String?)?.trim() ?? '';
    if (otherDev.isEmpty || otherStu.isEmpty) return false;
    if (otherDev != dev) return false;
    return otherStu != stu;
  }

  /// Tests only.
  static Future<void> clearForTest() async {
    await AttendanceLocalQueues.removeKey(_hiveKey);
  }
}
