import 'kiu_admin_registration_number.dart';
import 'staff_auth_email.dart';

/// Registration numbers lecturers may enter (KIU4235S or assigned KIU-#### staff ID).
abstract final class LecturerRegistrationNumber {
  static String? validateFormat(String raw) {
    if (KiuAdminRegistrationNumber.validateFormat(raw) == null) return null;
    if (StaffAuthEmail.normalizeStaffNumberFlexible(raw) != null) return null;
    return 'Use format ${KiuAdminRegistrationNumber.example} '
        'or staff ID KIU-0001.';
  }

  /// True when [raw] is a KIU staff ID (KIU-####) or registration number (KIU1234S).
  static bool isValidLookupId(String raw) => validateFormat(raw) == null;

  /// Canonical id for lecturer lookup, or null when [raw] is not recognized.
  static String? normalizeForLookup(String raw) {
    if (!isValidLookupId(raw)) return null;
    return normalize(raw);
  }

  static String normalize(String raw) {
    if (KiuAdminRegistrationNumber.validateFormat(raw) == null) {
      return KiuAdminRegistrationNumber.normalize(raw);
    }
    final staff = StaffAuthEmail.normalizeStaffNumberFlexible(raw);
    if (staff != null) return staff;
    return raw.trim().toUpperCase();
  }

  static String get exampleHint =>
      '${KiuAdminRegistrationNumber.example} or KIU-0001';
}
