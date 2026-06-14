import 'package:flutter/foundation.dart';

import '../auth/auth_repository.dart';
import '../auth/student_registration_number.dart';
import 'u_panel_rtd.dart';

/// Maps Firebase Auth uid → registration number so RTD rules can authorize
/// reads on `attendance_records/by_student/{registration}/…`.
abstract final class StudentRtdIndex {
  StudentRtdIndex._();

  static const _root = 'student_rtd_index';

  static String pathForUid(String uid) => '$_root/${uid.trim()}';

  /// Writes the signed-in student's registration to RTD (idempotent).
  static Future<bool> publishCurrentStudentRegistration() async {
    if (!AuthRepository.instance.isLoggedIn) return false;
    final uid = AuthRepository.instance.currentFirebaseUid?.trim();
    if (uid == null || uid.isEmpty) return false;
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg == null || reg.isEmpty) return false;
    final normalized = StudentRegistrationNumber.normalize(reg);
    if (normalized.isEmpty) return false;

    final db = tryUPanelDatabase();
    if (db == null) return false;

    final ref = db.ref(pathForUid(uid));
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await ref.set(normalized);
        final verify = await ref.get().timeout(const Duration(seconds: 3));
        final value = verify.value?.toString().trim() ?? '';
        if (value == normalized) return true;
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint(
            'StudentRtdIndex.publish attempt ${attempt + 1} failed: $e',
          );
          debugPrint('$st');
        }
      }
      await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
    }
    return false;
  }
}
