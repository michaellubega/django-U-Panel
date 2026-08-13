import 'user_role.dart';

/// Pure attendance-tab role routing (student sign-in vs staff lists).
abstract final class AttendanceRoleRouting {
  static bool showsStaffAttendanceUi({
    required bool isLoggedIn,
    required bool roleCheckDone,
    required bool isSyntheticStaffAuthIdentity,
    required bool isStaffAuthIdentity,
    required bool isLikelyStudent,
    required bool isStudentAuthIdentity,
    required UserRole resolvedRole,
  }) {
    if (!isLoggedIn) return false;
    if (!roleCheckDone) {
      if (isSyntheticStaffAuthIdentity || isStaffAuthIdentity) return true;
      if (isLikelyStudent) return false;
      return !isStudentAuthIdentity;
    }
    return resolvedRole != UserRole.student;
  }

  static bool scopesAttendanceToSignedInUser({
    required bool showsStaffAttendanceUi,
    required bool adminCheckDone,
    required bool isAdmin,
    required bool isKiuAdmin,
    required bool isLecturer,
    required bool roleCheckDone,
    required bool isSyntheticStaffAuthIdentity,
    required bool isStaffAuthIdentity,
    required bool isLikelyStudent,
    required UserRole resolvedRole,
  }) {
    if (!showsStaffAttendanceUi) return false;
    if (adminCheckDone && isAdmin) return false;
    if (adminCheckDone && isKiuAdmin) return true;
    if (isLecturer && !isAdmin) return true;
    if (isStaffAuthIdentity || isSyntheticStaffAuthIdentity) return true;
    if (!roleCheckDone && !isLikelyStudent) return true;
    return resolvedRole == UserRole.lecturer ||
        resolvedRole == UserRole.kiuAdmin;
  }
}
