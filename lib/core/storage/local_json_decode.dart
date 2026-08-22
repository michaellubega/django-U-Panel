import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Decodes JSON text stored locally; returns null and optionally clears [rawKey]
/// when the payload is corrupt so the next read does not keep failing.
Future<T?> decodeStoredJson<T>({
  required String raw,
  required String storageKey,
  required Future<void> Function(String key) removeKey,
  required T Function(dynamic decoded) parse,
  String? debugLabel,
}) async {
  if (raw.isEmpty) return null;
  var text = raw.trim();
  if (text.startsWith('\uFEFF')) {
    text = text.substring(1).trimLeft();
  }
  if (text.isEmpty) return null;
  try {
    return parse(jsonDecode(text));
  } on FormatException catch (e) {
    if (kDebugMode) {
      final label = debugLabel ?? storageKey;
      debugPrint(
        'decodeStoredJson: dropped corrupt payload for $label: $e',
      );
    }
    await _safeRemoveKey(removeKey, storageKey);
    return null;
  } catch (e) {
    if (kDebugMode) {
      final label = debugLabel ?? storageKey;
      debugPrint('decodeStoredJson: dropped invalid payload for $label: $e');
    }
    await _safeRemoveKey(removeKey, storageKey);
    return null;
  }
}

Future<void> _safeRemoveKey(
  Future<void> Function(String key) removeKey,
  String storageKey,
) async {
  try {
    await removeKey(storageKey);
  } catch (e) {
    if (kDebugMode) {
      debugPrint('decodeStoredJson: could not clear $storageKey: $e');
    }
  }
}
