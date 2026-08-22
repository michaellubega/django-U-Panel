/// Synthetic Firebase Auth email for lecturer staff numbers (KIU-####).
///
/// Users type `KIU-0001` at login; the app converts to a valid email form.
abstract final class StaffAuthEmail {
  /// Domain segment for lecturer accounts (not a real mailbox).
  static const syntheticEmailDomain = 'staff.upanel.local';

  /// Password for lecturer or QA accounts created by an admin until changed in Settings.
  static const defaultLecturerPassword = 'admin@kiu';

  /// Normalizes `KIU-0001` / `kiu-0001` to canonical `KIU-0001`.
  static String? normalizeStaffNumber(String raw) {
    final t = raw.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
    if (!RegExp(r'^KIU-\d{4}$').hasMatch(t)) return null;
    return t;
  }

  /// Like [normalizeStaffNumber] but also accepts `0001`, `KIU0001`, etc.
  static String? normalizeStaffNumberFlexible(String raw) {
    final canonical = normalizeStaffNumber(raw);
    if (canonical != null) return canonical;
    final t = raw.trim().toUpperCase().replaceAll(RegExp(r'[\s\-]'), '');
    if (RegExp(r'^\d{4}$').hasMatch(t)) return 'KIU-$t';
    if (RegExp(r'^KIU\d{4}$').hasMatch(t)) {
      return 'KIU-${t.substring(3)}';
    }
    return null;
  }

  /// `KIU-0001` -> `kiu0001@staff.upanel.local` (Firebase-friendly, unique per staff id).
  static String? staffNumberToSyntheticEmail(String staffNumber) {
    final n = normalizeStaffNumber(staffNumber);
    if (n == null) return null;
    final local = n.replaceAll('-', '').toLowerCase();
    return '$local@$syntheticEmailDomain';
  }

  /// Reverse: synthetic email -> display staff number, or null if not our domain.
  static String? syntheticEmailToStaffNumber(String email) {
    final e = email.trim().toLowerCase();
    final at = e.indexOf('@');
    if (at <= 0) return null;
    final domain = e.substring(at + 1);
    if (domain != syntheticEmailDomain) return null;
    final local = e.substring(0, at);
    if (!RegExp(r'^kiu\d{4}$').hasMatch(local)) return null;
    final digits = local.substring(3);
    return 'KIU-$digits';
  }

  /// True if [rawLogin] is only a staff id pattern (no @).
  static bool looksLikeStaffNumberOnly(String rawLogin) {
    final t = rawLogin.trim();
    if (t.contains('@')) return false;
    return normalizeStaffNumber(t) != null;
  }

  /// Resolves login input to the email string passed to Firebase Auth.
  /// Returns null if staff-shaped but invalid.
  static String? resolveLoginEmail(String rawLogin) {
    final trimmed = rawLogin.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.contains('@')) {
      final staff = syntheticEmailToStaffNumber(trimmed);
      if (staff != null) {
        return staffNumberToSyntheticEmail(staff);
      }
      return trimmed;
    }
    final n = normalizeStaffNumber(trimmed);
    if (n == null) return trimmed;
    return staffNumberToSyntheticEmail(n);
  }
}
