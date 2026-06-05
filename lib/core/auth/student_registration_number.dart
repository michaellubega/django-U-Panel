/// KIU student registration number format (e.g. 2025-08-41310).
abstract final class StudentRegistrationNumber {
  static const example = '2025-08-41310';

  /// `YYYY-MM-#####` (4-digit year, 2-digit month, 5-digit id).
  static final RegExp _pattern = RegExp(r'^\d{4}-\d{2}-\d{5}$');

  static String normalize(String raw) => raw.trim();

  /// Null when valid; otherwise a user-facing error.
  static String? validateFormat(String raw) {
    final r = normalize(raw);
    if (r.isEmpty) return 'Enter your registration number.';
    if (!_pattern.hasMatch(r)) {
      return 'Use format YYYY-MM-##### (e.g. $example).';
    }
    return null;
  }

  /// User-facing message when [reg] is locked to another Firebase account.
  static String messageRegLinkedToAnotherAccount(String reg) =>
      'Registration number $reg is already linked to another student account. '
      'Sign in with the @studmc.kiu.ac.ug email used when that number was first '
      'registered, or contact ICT if you need help.';

  /// User-facing message when [reg] is locked to a different school email.
  static String messageRegLinkedToDifferentEmail(String reg) =>
      'Registration number $reg is already linked to a different school email. '
      'Use that email to sign in, or contact ICT if your student mailbox changed.';
}
