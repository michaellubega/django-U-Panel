/// KIU student mailbox format for self-registration and sign-in.
abstract final class StudentAuthEmail {
  static const studentEmailDomains = [
    'studmc.kiu.ac.ug',
    'studwc.kiu.ac.ug',
  ];

  /// Primary campus domain (examples / legacy references).
  static const studentEmailDomain = 'studmc.kiu.ac.ug';

  static const exampleEmail = 'sabiti.lubega@studmc.kiu.ac.ug';

  static const exampleEmailWest = 'sabiti.lubega@studwc.kiu.ac.ug';

  /// `firstname.lastname@studmc.kiu.ac.ug` or `@studwc.kiu.ac.ug` (lowercase).
  static final RegExp _studentEmailPattern = RegExp(
    r'^[a-z][a-z0-9]*\.[a-z][a-z0-9]*@(studmc|studwc)\.kiu\.ac\.ug$',
  );

  static String studentDomainsLabel() =>
      studentEmailDomains.map((d) => '@$d').join(' or ');

  static String normalizeStudentEmail(String raw) {
    var s = raw.trim();
    s = s.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF\u2060\u200E\u200F]'), '');
    s = s.replaceAll(RegExp(r'^[|\uFF5C\u007C\u00A0\s]+'), '');
    return s.trim().toLowerCase();
  }

  static bool isStudentMailbox(String email) {
    final e = normalizeStudentEmail(email);
    if (!e.contains('@')) return false;
    final domain = e.split('@').last;
    return studentEmailDomains.contains(domain);
  }

  static String? _studentDomain(String email) {
    final domain = normalizeStudentEmail(email).split('@').last;
    return studentEmailDomains.contains(domain) ? domain : null;
  }

  /// Sign-in / password reset: KIU student format only.
  static String? validateLoginFormat(String raw) => validateFormat(raw);

  /// Null when valid; otherwise a user-facing error.
  static String? validateFormat(String raw) {
    final e = normalizeStudentEmail(raw);
    if (e.isEmpty) {
      return 'Enter your KIU school email.';
    }
    if (!e.contains('@')) {
      return 'Enter your KIU school email (e.g. $exampleEmail).';
    }
    final domain = _studentDomain(e);
    if (domain == null) {
      return 'You must use your official KIU school email (${studentDomainsLabel()}). '
          'Personal addresses (Gmail, Yahoo, etc.) and other domains are not accepted.';
    }
    if (!_studentEmailPattern.hasMatch(e)) {
      return 'Use your school email as firstname.lastname@$domain '
          '(e.g. ${domain == studentEmailDomains.last ? exampleEmailWest : exampleEmail}).';
    }
    return null;
  }
}
