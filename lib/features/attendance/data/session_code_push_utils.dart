import '../../../core/connectivity/app_connectivity.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';

/// Helpers for session-code push / notice handling (no auto check-in).
class SessionCodePushUtils {
  SessionCodePushUtils._();

  /// Extracts a join code from FCM [data] or notice fields.
  static String? codeFromPushData(Map<String, dynamic> data) {
    final kind = (data['kind'] as String? ?? '').trim().toLowerCase();
    if (kind.isNotEmpty && kind != 'sessioncode') return null;
    final raw = (data['sessionCode'] as String? ?? '').trim();
    if (raw.isEmpty) return null;
    final normalized = normalizeSessionCodeInput(raw);
    return isValidJoinCodeFormat(normalized) ? normalized : null;
  }

  /// True when [code] belongs to an active remote-learning session.
  static Future<bool> isRemoteLearningSessionCode(String rawCode) async {
    final code = normalizeSessionCodeInput(rawCode);
    if (!isValidJoinCodeFormat(code)) return false;
    await AttendanceRepository.instance.loadAll(force: false);
    var session = AttendanceRepository.instance.validateSessionCode(code);
    if (session == null && AppConnectivity.instance.isOnline) {
      session = await AttendanceRepository.instance
          .resolveActiveSessionByCodeForSignIn(code);
    }
    return session?.remoteLearning == true;
  }
}
