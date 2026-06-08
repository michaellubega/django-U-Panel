import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_json_decode.dart';

/// Durable local storage for offline attendance queues (Hive when available).
///
/// If Hive cannot open (or concurrent init races), falls back to
/// [SharedPreferences] so pending check-ins and session codes still persist.
///
/// On first successful Hive open, migrates legacy SharedPreferences payloads once.
class AttendanceLocalQueues {
  AttendanceLocalQueues._();

  static const _boxName = 'u_panel_attendance_queues';
  static const _hiveDisabledKey = 'attendance_queues_hive_disabled_v1';

  /// Hive value keys (JSON strings, same shape as before).
  static const checkInsJsonKey = 'pending_attendance_check_ins';
  static const sessionCodesJsonKey = 'pending_attendance_session_codes';
  static const sessionSyncSummaryJsonKey =
      'pending_attendance_session_sync_summary';
  static const sessionCreatesJsonKey = 'pending_attendance_session_creates';
  static const listCreatesJsonKey = 'pending_attendance_list_creates';
  static const campusPresenceJsonKey = 'pending_campus_presence';
  static const campusGeofenceCacheJsonKey = 'cached_campus_geofence_v1';

  /// Legacy SharedPreferences keys (must match previous queue files).
  static const _legacyPrefsCheckIns = 'pending_attendance_check_ins';
  static const _legacyPrefsSessionCodes = 'pending_attendance_session_codes';
  static const _legacyPrefsSyncSummary =
      'pending_attendance_session_sync_summary';

  static const _knownQueueKeys = <String>[
    checkInsJsonKey,
    sessionCodesJsonKey,
    sessionSyncSummaryJsonKey,
    sessionCreatesJsonKey,
    listCreatesJsonKey,
    campusPresenceJsonKey,
    campusGeofenceCacheJsonKey,
  ];

  static Box<dynamic>? _box;
  static bool _opened = false;
  /// True when Hive is skipped and queue I/O uses SharedPreferences only.
  static bool _prefsFallback = false;

  /// Last resort when SharedPreferences cannot open (corrupt Windows JSON file).
  static final Map<String, String> _memoryPrefs = <String, String>{};
  static bool _memoryPrefsOnly = false;

  /// Single in-flight Hive open so parallel callers do not call [Hive.initFlutter] twice.
  static Future<void>? _hiveOpening;

  static Future<void> ensureInitialized() async {
    if (_memoryPrefsOnly) {
      _prefsFallback = true;
      return;
    }
    if (_prefsFallback) return;
    if (_opened) return;

    // Hive on web is slow and unnecessary — use SharedPreferences only.
    if (kIsWeb) {
      _prefsFallback = true;
      return;
    }

    if (!_hiveDisabledChecked) {
      _hiveDisabledChecked = true;
      try {
        final prefs = await _safePrefsInstance();
        if (prefs != null && prefs.getBool(_hiveDisabledKey) == true) {
          _prefsFallback = true;
          return;
        }
      } catch (_) {
        _prefsFallback = true;
        return;
      }
    }

    _hiveOpening ??= _openHiveAndMigrate();
    try {
      await _hiveOpening;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint(
          'AttendanceLocalQueues: Hive init failed, using SharedPreferences. $e',
        );
        debugPrint('$st');
      }
      _hiveOpening = null;
      await _usePrefsFallbackPersisted();
    }
  }

  static bool _hiveDisabledChecked = false;

  /// Deletes corrupt Hive/prefs files and re-opens storage (startup recovery).
  static Future<void> recoverFromCorruptStorage() async {
    if (kDebugMode) {
      debugPrint('AttendanceLocalQueues: recovering from corrupt local storage…');
    }
    try {
      await _box?.close();
    } catch (_) {}
    _box = null;
    _opened = false;
    _hiveOpening = null;
    _hiveDisabledChecked = false;
    _prefsFallback = false;
    _memoryPrefsOnly = false;
    _memoryPrefs.clear();
    await _deleteHiveBoxFromDisk();
    await _tryDeleteCorruptPrefsFile();
    await ensureInitialized();
  }

  /// Clears known queue keys that throw while reading (corrupt Windows prefs).
  static Future<void> sanitizeCorruptStorage() async {
    try {
      await ensureInitialized();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AttendanceLocalQueues.sanitizeCorruptStorage init failed: $e');
        debugPrint('$st');
      }
      await recoverFromCorruptStorage();
    }

    for (final key in _knownQueueKeys) {
      await _sanitizeJsonKey(key);
    }

    if (!_prefsFallback && _box != null) {
      for (final key in _box!.keys.toList()) {
        if (key is String && key.startsWith('attendance_snapshot_')) {
          await _sanitizeJsonKey(key);
        }
      }
    }
  }

  static Future<void> _sanitizeJsonKey(String key) async {
    try {
      final raw = await readString(key);
      if (raw == null || raw.isEmpty) return;
      await decodeStoredJson<dynamic>(
        raw: raw,
        storageKey: key,
        removeKey: removeKey,
        parse: (decoded) => decoded,
        debugLabel: key,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AttendanceLocalQueues: sanitize dropped $key: $e');
      }
      try {
        await removeKey(key);
      } catch (_) {}
    }
  }

  static Future<void> _usePrefsFallbackPersisted() async {
    _prefsFallback = true;
    try {
      final prefs = await _safePrefsInstance();
      if (prefs != null) {
        await prefs.setBool(_hiveDisabledKey, true);
      }
    } catch (_) {}
    try {
      await _box?.close();
    } catch (_) {}
    _box = null;
    _opened = false;
  }

  static Future<void> _openHiveAndMigrate() async {
    await Hive.initFlutter();
    final box = await _openBoxRecoveringFromCorruption();
    try {
      await _migrateFromSharedPreferencesOnce(box);
      _box = box;
      _opened = true;
      try {
        final prefs = await _safePrefsInstance();
        if (prefs != null) {
          await prefs.remove(_hiveDisabledKey);
        }
      } catch (_) {}
    } catch (_) {
      await box.close();
      rethrow;
    }
  }

  static Future<Box<dynamic>> _openBoxRecoveringFromCorruption() async {
    try {
      return await Hive.openBox<dynamic>(_boxName);
    } catch (e) {
      if (!_looksLikeCorruptPayload(e)) rethrow;
      if (kDebugMode) {
        debugPrint(
          'AttendanceLocalQueues: corrupt Hive box — deleting and reopening.',
        );
      }
      await _deleteHiveBoxFromDisk();
      return Hive.openBox<dynamic>(_boxName);
    }
  }

  static bool _looksLikeCorruptPayload(Object e) {
    if (e is FormatException) return true;
    final text = e.toString();
    return text.contains('FormatException') ||
        text.contains('Unexpected character');
  }

  static Future<void> _deleteHiveBoxFromDisk() async {
    try {
      if (Hive.isBoxOpen(_boxName)) {
        await Hive.box(_boxName).close();
      }
    } catch (_) {}
    try {
      await Hive.deleteBoxFromDisk(_boxName);
    } catch (_) {}
  }

  static Future<bool> _tryDeleteCorruptPrefsFile() async {
    if (kIsWeb) return false;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/shared_preferences.json');
      if (await file.exists()) {
        await file.delete();
        if (kDebugMode) {
          debugPrint(
            'AttendanceLocalQueues: deleted corrupt shared_preferences.json',
          );
        }
        return true;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AttendanceLocalQueues: could not delete prefs file: $e');
      }
    }
    return false;
  }

  static Future<SharedPreferences?> _safePrefsInstance() async {
    if (_memoryPrefsOnly) return null;
    try {
      return await SharedPreferences.getInstance();
    } catch (e) {
      if (!_looksLikeCorruptPayload(e)) rethrow;
      if (kDebugMode) {
        debugPrint(
          'AttendanceLocalQueues: SharedPreferences.getInstance failed: $e',
        );
      }
      final deleted = await _tryDeleteCorruptPrefsFile();
      if (deleted) {
        try {
          return await SharedPreferences.getInstance();
        } catch (retryError) {
          if (kDebugMode) {
            debugPrint(
              'AttendanceLocalQueues: prefs retry after delete failed: $retryError',
            );
          }
        }
      }
      _memoryPrefsOnly = true;
      _prefsFallback = true;
      if (kDebugMode) {
        debugPrint(
          'AttendanceLocalQueues: using in-memory queue storage until restart.',
        );
      }
      return null;
    }
  }

  static Future<void> _migrateFromSharedPreferencesOnce(Box<dynamic> b) async {
    if (_prefsFallback) return;
    final prefs = await _safePrefsInstance();
    if (prefs == null) return;

    Future<void> migrateOne(String legacyKey, String hiveKey) async {
      if (b.get(hiveKey) != null) return;
      final raw = await _safePrefsGetString(prefs, legacyKey);
      if (raw == null || raw.isEmpty) return;
      await b.put(hiveKey, raw);
      await _safePrefsRemove(prefs, legacyKey);
    }

    await migrateOne(_legacyPrefsCheckIns, checkInsJsonKey);
    await migrateOne(_legacyPrefsSessionCodes, sessionCodesJsonKey);
    await migrateOne(_legacyPrefsSyncSummary, sessionSyncSummaryJsonKey);
  }

  static Future<String?> _safePrefsGetString(
    SharedPreferences? prefs,
    String key,
  ) async {
    if (prefs == null) {
      return _memoryPrefs[key];
    }
    try {
      return prefs.getString(key);
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          'AttendanceLocalQueues: prefs read failed for $key — clearing. $e',
        );
      }
      await _safePrefsRemove(prefs, key);
      return null;
    }
  }

  static Future<void> _safePrefsSetString(
    SharedPreferences? prefs,
    String key,
    String value,
  ) async {
    if (prefs == null) {
      _memoryPrefs[key] = value;
      return;
    }
    try {
      await prefs.setString(key, value);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AttendanceLocalQueues: prefs write failed for $key: $e');
      }
      await _safePrefsRemove(prefs, key);
      try {
        await prefs.setString(key, value);
      } catch (_) {}
    }
  }

  static Future<void> _safePrefsRemove(SharedPreferences? prefs, String key) async {
    if (prefs == null) {
      _memoryPrefs.remove(key);
      return;
    }
    try {
      await prefs.remove(key);
    } catch (_) {}
    _memoryPrefs.remove(key);
  }

  static Future<String?> readString(String key) async {
    try {
      await ensureInitialized();
      if (_prefsFallback) {
        final p = await _safePrefsInstance();
        return _safePrefsGetString(p, key);
      }
      try {
        final v = _box!.get(key);
        if (v is String) return v;
        if (v != null) {
          if (kDebugMode) {
            debugPrint(
              'AttendanceLocalQueues: dropped non-string Hive value for $key.',
            );
          }
          await _box!.delete(key);
        }
        return null;
      } catch (e) {
        if (!_looksLikeCorruptPayload(e)) rethrow;
        if (kDebugMode) {
          debugPrint('AttendanceLocalQueues: corrupt Hive value for $key: $e');
        }
        try {
          await _box!.delete(key);
        } catch (_) {}
        return null;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AttendanceLocalQueues.readString failed for $key: $e');
      }
      try {
        await removeKey(key);
      } catch (_) {}
      return null;
    }
  }

  static Future<void> writeString(String key, String value) async {
    try {
      await ensureInitialized();
      if (_prefsFallback) {
        final p = await _safePrefsInstance();
        await _safePrefsSetString(p, key, value);
        return;
      }
      await _box!.put(key, value);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AttendanceLocalQueues.writeString failed for $key: $e');
      }
    }
  }

  static Future<void> removeKey(String key) async {
    try {
      await ensureInitialized();
      if (_prefsFallback) {
        final p = await _safePrefsInstance();
        await _safePrefsRemove(p, key);
        return;
      }
      await _box!.delete(key);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AttendanceLocalQueues.removeKey failed for $key: $e');
      }
    }
  }

  /// Drops offline check-in / session-code queues (e.g. on sign-out).
  static Future<void> clearAllPending() async {
    await removeKey(checkInsJsonKey);
    await removeKey(sessionCodesJsonKey);
    await removeKey(sessionSyncSummaryJsonKey);
    await removeKey(sessionCreatesJsonKey);
    await removeKey(listCreatesJsonKey);
    await removeKey(campusPresenceJsonKey);
  }
}
