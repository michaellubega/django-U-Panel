import 'dart:io' show Platform;
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefsKey = 'u_panel_install_device_id';

/// Stable-ish id for this install/device, used to limit one present check-in
/// per session per physical device.
class DeviceIdentity {
  DeviceIdentity._();

  static String? _cached;

  /// Clears in-memory cache (e.g. tests).
  static void clearMemoryCacheForTest() => _cached = null;

  static Future<String> resolve() async {
    final existing = _cached;
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    late final String id;
    if (kIsWeb) {
      id = await _persistedFallback('web');
    } else if (Platform.isAndroid) {
      id = await _nativeAndroidId();
    } else if (Platform.isIOS) {
      id = await _nativeIosId();
    } else {
      id = await _persistedFallback(Platform.operatingSystem);
    }

    final trimmed = id.trim();
    _cached = trimmed.isNotEmpty ? trimmed : await _persistedFallback('fallback');
    return _cached!;
  }

  /// [device_info_plus] is not registered after hot reload / some embeds;
  /// fall back to a stable per-install id so check-in still works.
  static Future<String> _nativeAndroidId() async {
    try {
      final android = await DeviceInfoPlugin().androidInfo;
      final raw = android.id.trim();
      if (raw.isNotEmpty) return raw;
    } on MissingPluginException {
      // ignore
    } catch (_) {
      // ignore
    }
    return _persistedFallback('android');
  }

  static Future<String> _nativeIosId() async {
    try {
      final ios = await DeviceInfoPlugin().iosInfo;
      final raw = ios.identifierForVendor?.trim() ?? '';
      if (raw.isNotEmpty) return raw;
    } on MissingPluginException {
      // ignore
    } catch (_) {
      // ignore
    }
    return _persistedFallback('ios');
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
