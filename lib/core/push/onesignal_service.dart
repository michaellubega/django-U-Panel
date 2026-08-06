import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb, TargetPlatform;

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import '../../features/attendance/attendance_list_hierarchy.dart';
import 'push_topic_names.dart';

import 'onesignal_bridge_stub.dart'
    if (dart.library.io) 'onesignal_bridge_mobile.dart' as bridge;

/// OneSignal push (replaces Firebase Cloud Messaging).
abstract final class OneSignalService {
  OneSignalService._();

  static bool get supported => bridge.bridgeOneSignalSupported;

  static Future<void> initialize() => bridge.bridgeInitOneSignal();

  static Future<void> syncForCurrentUser() async {
    if (!supported) return;
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn || auth.needsEmailVerification || !auth.roleCheckDone) {
      await bridge.bridgeLogoutOneSignal();
      return;
    }

    final playerId = await bridge.bridgeGetPlayerId();
    if (playerId == null || playerId.isEmpty) return;

    final tags = _tagsForUser(auth);
    await bridge.bridgeSetTags(tags);
    await _registerWithBackend(playerId, tags);
  }

  static Future<void> logout() => bridge.bridgeLogoutOneSignal();

  static Map<String, String> _tagsForUser(AuthRepository auth) {
    final tags = <String, String>{kPushAllNoticesTag: 'true'};

    final uid = auth.currentUserId?.trim();
    if (uid != null && uid.isNotEmpty) {
      if (auth.isLecturer) tags[pushLecturerNoticeTag(uid)] = 'true';
      if (auth.isKiuAdmin) tags[kPushKiuAdminsTag] = 'true';
    }

    final reg = auth.currentRegistrationNumber?.trim();
    if (reg != null && reg.isNotEmpty) {
      tags[pushStudentNoticeTag(reg)] = 'true';
    }

    for (final list in attendanceListsForCurrentStaff()) {
      final id = list.id.trim();
      if (id.isNotEmpty) tags[pushListNoticeTag(id)] = 'true';
    }

    return tags;
  }

  static Future<void> _registerWithBackend(
    String playerId,
    Map<String, String> tags,
  ) async {
    try {
      await ApiClient.instance.postJson('/api/push/register/', {
        'player_id': playerId,
        'platform': _platformName(),
        'tags': tags,
      });
    } catch (e, st) {
      debugPrint('OneSignalService backend register: $e');
      debugPrint('$st');
    }
  }

  static String _platformName() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return 'unknown';
    }
  }
}
