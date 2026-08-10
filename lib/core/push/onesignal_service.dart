import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb, TargetPlatform;

import '../api/api_client.dart';
import '../auth/auth_repository.dart';
import '../../features/attendance/attendance_list_hierarchy.dart';
import '../../features/attendance/models/attendance_models.dart';
import 'push_topic_names.dart';

import 'onesignal_service_impl_stub.dart'
    if (dart.library.io) 'onesignal_service_impl_mobile.dart' as impl;

/// Centralized OneSignal wrapper — all SDK calls go through this class.
abstract final class OneSignalService {
  OneSignalService._();

  static bool get supported => impl.oneSignalImplSupported;

  /// Call from [main] before [runApp].
  static void initializeSdk() => impl.oneSignalImplInitializeSdk();

  static Future<void> initialize({
    void Function(Map<String, dynamic>)? onOpened,
    void Function(Map<String, dynamic>)? onForeground,
    void Function()? onSubscriptionChanged,
  }) =>
      impl.oneSignalImplAttachHandlers(
        onOpened: onOpened,
        onForeground: onForeground,
        onSubscriptionChanged: onSubscriptionChanged,
      );

  static void setupIntegrationVerification(
    void Function(void Function() onRequestPermission) showDialog,
  ) =>
      impl.oneSignalImplSetupIntegrationVerification(showDialog);

  static Future<void> syncForCurrentUser() async {
    if (!supported) return;
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn || auth.needsEmailVerification || !auth.roleCheckDone) {
      await logout();
      return;
    }

    final userId = auth.currentUserId?.trim();
    if (userId != null && userId.isNotEmpty) {
      await impl.oneSignalImplLogin(userId);
    }

    final playerId = await impl.oneSignalImplGetPlayerId();
    if (playerId == null || playerId.isEmpty) return;

    final tags = _tagsForUser(auth);
    await impl.oneSignalImplSetTags(tags);
    await _registerWithBackend(playerId, tags);
  }

  static Future<void> logout() async {
    if (supported) {
      final playerId = await impl.oneSignalImplGetPlayerId();
      if (playerId != null && playerId.isNotEmpty) {
        try {
          await ApiClient.instance.delete(
            '/api/push/register/?player_id=${Uri.encodeComponent(playerId)}',
          );
        } catch (e, st) {
          debugPrint('OneSignalService backend unregister: $e');
          debugPrint('$st');
        }
      }
    }
    await impl.oneSignalImplLogout();
  }

  static Future<bool> requestPermission() => impl.oneSignalImplRequestPermission();

  static Map<String, String> _tagsForUser(AuthRepository auth) {
    final tags = <String, String>{kPushAllNoticesTag: 'true'};

    final uid = auth.currentUserId?.trim();
    if (uid != null && uid.isNotEmpty) {
      if (auth.isLecturer) tags[pushLecturerNoticeTag(uid)] = 'true';
      if (auth.isKiuAdmin) tags[kPushKiuAdminsTag] = 'true';
    }

    final reg = auth.currentRegistrationNumber?.trim();
    if (reg != null && reg.isNotEmpty) {
      final student = AttendanceStore.findStudentByReg(reg);
      final studentId = student?.id.trim();
      if (studentId != null && studentId.isNotEmpty) {
        tags[pushStudentNoticeTag(studentId)] = 'true';
      }
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
