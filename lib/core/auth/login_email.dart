import 'kiu_admin_registration_number.dart';
import 'kiu_staff_auth_email.dart';
import 'staff_auth_email.dart';
import 'student_auth_email.dart';

/// Classifies and normalizes login / password-reset email input.
abstract final class LoginEmail {
  /// Trimmed login string after staff-id → synthetic resolution.
  static String resolve(String raw) =>
      StaffAuthEmail.resolveLoginEmail(raw)?.trim() ?? '';

  static bool isSyntheticStaff(String raw) {
    final resolved = resolve(raw);
    return StaffAuthEmail.syntheticEmailToStaffNumber(resolved) != null;
  }

  static bool isStaffNumberOnly(String raw) =>
      StaffAuthEmail.looksLikeStaffNumberOnly(raw);

  static bool isKiuRegistrationNumberOnly(String raw) =>
      KiuAdminRegistrationNumber.looksLikeRegistrationNumberOnly(raw);

  static bool isKiuStaffMailbox(String raw) =>
      KiuStaffAuthEmail.isStaffMailbox(raw) ||
      KiuStaffAuthEmail.skipsVerification(raw);

  static bool isStudentMailbox(String raw) =>
      StudentAuthEmail.isStudentMailbox(raw);

  /// Firebase Auth email for password reset (lowercase, trimmed).
  static String normalizeForPasswordReset(String raw) {
    final resolved = resolve(raw);
    if (isKiuStaffMailbox(resolved)) {
      return KiuStaffAuthEmail.normalizeStaffEmail(resolved);
    }
    return StudentAuthEmail.normalizeStudentEmail(resolved);
  }

  /// Null when valid for sign-in / password reset; otherwise user-facing error.
  static String? validateForPasswordReset(String raw) {
    if (isStaffNumberOnly(raw)) return null;
    if (isKiuRegistrationNumberOnly(raw)) {
      return 'Staff registration numbers cannot reset a password by email. '
          'Use your @kiu.ac.ug email, or ask your administrator.';
    }
    final resolved = resolve(raw);
    if (resolved.isEmpty) {
      return 'Enter your KIU school email.';
    }
    if (!resolved.contains('@')) {
      return 'Enter your KIU school email '
          '(e.g. ${StudentAuthEmail.exampleEmail} or ${KiuStaffAuthEmail.exampleEmail}).';
    }
    if (isSyntheticStaff(raw)) return null;
    if (isKiuStaffMailbox(resolved)) {
      return KiuStaffAuthEmail.validateLoginFormat(resolved);
    }
    return StudentAuthEmail.validateLoginFormat(resolved);
  }

  static String supportedDomainsHint() =>
      'KIU student (${StudentAuthEmail.studentDomainsLabel()}) or staff (@${KiuStaffAuthEmail.staffEmailDomain}) email.';
}
