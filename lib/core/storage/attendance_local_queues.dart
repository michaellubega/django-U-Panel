import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Durable local storage for offline attendance queues (Hive when available).
///
/// If Hive cannot open (or concurrent init races), falls back to
/// [SharedPreferences] so pending check-ins and session codes still persist.
///
/// On first successful Hive open, migrates legacy SharedPreferences payloads once.
class AttendanceLocalQueues {
  AttendanceLocalQueues._();

  static const _boxName = 'u_panel_attendance_queues';

  /// Hive value keys (JSON strings, same shape as before).
  static const checkInsJsonKey = 'pending_attendance_check_ins';
  static const sessionCodesJsonKey = 'pending_attendance_session_codes';
  static const sessionSyncSummaryJsonKey =
      'pending_attendance_session_sync_summary';

  /// Legacy SharedPreferences keys (must match previous queue files).
  static const _legacyPrefsCheckIns = 'pending_attendance_check_ins';
  static const _legacyPrefsSessionCodes = 'pending_attendance_session_codes';
  static const _legacyPrefsSyncSummary =
      'pending_attendance_session_sync_summary';

  static Box<dynamic>? _box;
  static bool _opened = false;
  /// True when Hive is skipped and queue I/O uses SharedPreferences only.
  static bool _prefsFallback = false;

  /// Single in-flight Hive open so parallel callers do not call [Hive.initFlutter] twice.
  static Future<void>? _hiveOpening;

  static Future<void> ensureInitialized() async {
    if (_prefsFallback) return;
    if (_opened) return;

    _hiveOpening ??= _openHiveAndMigrate();
    try {
      await _hiveOpening;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AttendanceLocalQueues: Hive init failed, using SharedPreferences. $e');
        debugPrint('$st');
      }
      _hiveOpening = null;
      _prefsFallback = true;
      try {
        await _box?.close();
      } catch (_) {}
      _box = null;
      _opened = false;
    }
  }

  static Future<void> _openHiveAndMigrate() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<dynamic>(_boxName);
    try {
      await _migrateFromSharedPreferencesOnce(box);
      _box = box;
      _opened = true;
    } catch (_) {
      await box.close();
      rethrow;
    }
  }

  static Future<void> _migrateFromSharedPreferencesOnce(Box<dynamic> b) async {
    if (_prefsFallback) return;
    final prefs = await SharedPreferences.getInstance();

    Future<void> migrateOne(String legacyKey, String hiveKey) async {
      if (b.get(hiveKey) != null) return;
      final raw = prefs.getString(legacyKey);
      if (raw == null || raw.isEmpty) return;
      await b.put(hiveKey, raw);
      await prefs.remove(legacyKey);
    }

    await migrateOne(_legacyPrefsCheckIns, checkInsJsonKey);
    await migrateOne(_legacyPrefsSessionCodes, sessionCodesJsonKey);
    await migrateOne(_legacyPrefsSyncSummary, sessionSyncSummaryJsonKey);
  }

  static Future<String?> readString(String key) async {
    await ensureInitialized();
    if (_prefsFallback) {
      final p = await SharedPreferences.getInstance();
      return p.getString(key);
    }
    final v = _box!.get(key);
    if (v is String) return v;
    return null;
  }

  static Future<void> writeString(String key, String value) async {
    await ensureInitialized();
    if (_prefsFallback) {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, value);
      return;
    }
    await _box!.put(key, value);
  }

  static Future<void> removeKey(String key) async {
    await ensureInitialized();
    if (_prefsFallback) {
      final p = await SharedPreferences.getInstance();
      await p.remove(key);
      return;
    }
    await _box!.delete(key);
  }

  /// Drops offline check-in / session-code queues (e.g. on sign-out).
  static Future<void> clearAllPending() async {
    await removeKey(checkInsJsonKey);
    await removeKey(sessionCodesJsonKey);
    await removeKey(sessionSyncSummaryJsonKey);
  }
}
