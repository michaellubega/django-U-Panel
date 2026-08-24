import 'dart:io' show Platform;
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefsKey = 'u_panel_install_device_id';

/// Hardware ids that are reused across unrelated phones / emulators.
/// Using them as the check-in device id falsely blocks other students
/// on a session code that works on unique devices.
const _genericHardwareIds = {
  'unknown',
  '0',
  '9774d56d682e549c',
  '0000000000000000',
  'android',
  'null',
  'undefined',
};

/// Stable-ish id for this install/device, used to limit one present check-in
/// per session per physical device.
class DeviceIdentity {
  DeviceIdentity._();

  static String? _cached;

  /// Clears in-memory cache (e.g. tests).
  static void clearMemoryCacheForTest() => _cached = null;

  static void resetMemoryCacheForTests() => clearMemoryCacheForTest();

  @visibleForTesting
  static bool isGenericHardwareId(String raw) {
    final v = raw.trim().toLowerCase();
    return v.isEmpty || _genericHardwareIds.contains(v);
  }

  static Future<String> resolve() async {
    final existing = _cached;
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    // Per-install id is always unique. Raw ANDROID_ID is reused on emulators
    // and some handsets, which made a working session code fail on those phones.
    final installId = await _persistedFallback('install');
    final hardware = await _hardwareId();
    final id = isGenericHardwareId(hardware)
        ? installId
        : '${hardware}_$installId';

    final trimmed = id.trim();
    _cached = trimmed.isNotEmpty ? trimmed : installId;
    return _cached!;
  }

  static Future<String> _hardwareId() async {
    if (kIsWeb) return '';
    try {
      if (Platform.isAndroid) {
        final android = await DeviceInfoPlugin().androidInfo;
        return android.id.trim();
      }
      if (Platform.isIOS) {
        return (await DeviceInfoPlugin().iosInfo).identifierForVendor?.trim() ??
            '';
      }
    } on MissingPluginException {
      return '';
    } catch (_) {
      return '';
    }
    return '';
  }

  static Future<String> _persistedFallback(String prefix) async {
    final p = await SharedPreferences.getInstance();
    var v = p.getString(_prefsKey);
    if (v == null || v.isEmpty) {
      final rnd = Random.secure().nextInt(1 << 30);
      v =
          '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${rnd.toRadixString(16)}';
      await p.setString(_prefsKey, v);
    }
    return v;
  }
}
