/// KIU student mailbox format for self-registration and sign-in.
abstract final class StudentAuthEmail {
  static const studentEmailDomain = 'studmc.kiu.ac.ug';

  static const exampleEmail = 'sabiti.lubega@studmc.kiu.ac.ug';

  /// Sole non-@studmc.kiu.ac.ug address allowed at sign-in (not for registration).
  static const allowedNonKiuLoginEmail = 'michaeldieve@gmail.com';

  /// `firstname.lastname@studmc.kiu.ac.ug` (lowercase).
  static final RegExp _studentEmailPattern = RegExp(
    r'^[a-z][a-z0-9]*\.[a-z][a-z0-9]*@studmc\.kiu\.ac\.ug$',
  );

  static String normalizeStudentEmail(String raw) {
    var s = raw.trim();
    s = s.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF\u2060\u200E\u200F]'), '');
    s = s.replaceAll(RegExp(r'^[|\uFF5C\u007C\u00A0\s]+'), '');
    return s.trim().toLowerCase();
  }

  static bool isStudentMailbox(String email) {
    final e = normalizeStudentEmail(email);
    if (!e.contains('@')) return false;
    return e.endsWith('@$studentEmailDomain');
  }

  static bool isAllowedNonKiuLoginEmail(String raw) {
    return normalizeStudentEmail(raw) == allowedNonKiuLoginEmail;
  }

  /// Sign-in / password reset: KIU student format or [allowedNonKiuLoginEmail].
  static String? validateLoginFormat(String raw) {
    if (isAllowedNonKiuLoginEmail(raw)) return null;
    return validateFormat(raw);
  }

  /// Null when valid; otherwise a user-facing error.
  static String? validateFormat(String raw) {
    final e = normalizeStudentEmail(raw);
    if (e.isEmpty) {
      return 'Enter your KIU school email.';
    }
    if (!e.contains('@')) {
      return 'Enter your KIU school email (e.g. $exampleEmail).';
    }
    if (!e.endsWith('@$studentEmailDomain')) {
      return 'You must use your official KIU school email (@$studentEmailDomain). '
          'Personal addresses (Gmail, Yahoo, etc.) and other domains are not accepted.';
    }
    if (!_studentEmailPattern.hasMatch(e)) {
      return 'Use your school email as firstname.lastname@$studentEmailDomain '
          '(e.g. $exampleEmail).';
    }
    return null;
  }
}
