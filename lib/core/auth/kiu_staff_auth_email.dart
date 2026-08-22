import 'staff_auth_email.dart';
import 'student_auth_email.dart';

/// KIU staff mailbox format ([@kiu.ac.ug]) for administrator self-registration.
abstract final class KiuStaffAuthEmail {
  static const staffEmailDomain = 'kiu.ac.ug';
  static const exampleEmail = 'jane.doe@kiu.ac.ug';

  /// Emails that skip Firebase mailbox verification (bootstrap / ICT exceptions).
  static const verificationBypassEmails = {
    'michaeldieve7@gmail.com',
    'michaeldieve@gmail.com',
    'michaeldieve14@gmail.com',
  };

  /// True for ICT-approved Gmail (or other) exceptions — treated like staff mailboxes.
  static bool isVerificationBypassEmail(String raw) =>
      skipsVerification(raw);

  static bool skipsVerification(String raw) =>
      verificationBypassEmails.contains(normalizeStaffEmail(raw));

  static bool isStaffMailbox(String raw) {
    if (skipsVerification(raw)) return true;
    if (StudentAuthEmail.isStudentMailbox(raw)) return false;
    final e = normalizeStaffEmail(raw);
    if (!e.contains('@')) return false;
    final domain = e.split('@').last;
    if (domain == staffEmailDomain) return true;
    return domain.endsWith('.kiu.ac.ug') &&
        !StudentAuthEmail.studentEmailDomains.contains(domain);
  }

  static String normalizeStaffEmail(String raw) {
    var s = raw.trim().toLowerCase();
    s = s.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF\u2060\u200E\u200F]'), '');
    s = s.replaceAll(RegExp(r'^[|\uFF5C\u007C\u00A0\s]+'), '');
    return s.trim();
  }

  static String? validateFormat(String raw) {
    final e = normalizeStaffEmail(raw);
    if (e.isEmpty) return 'Enter your KIU staff email.';
    if (!e.contains('@')) {
      return 'Enter a valid email address (e.g. $exampleEmail).';
    }
    if (skipsVerification(e)) return null;
    if (!isStaffMailbox(e)) {
      return 'Staff accounts must use an official @$staffEmailDomain email address.';
    }
    final local = e.split('@').first;
    if (local.isEmpty || local.length < 2) {
      return 'Enter the part before @ in your KIU staff email.';
    }
    return null;
  }

  static String? validateLoginFormat(String raw) {
    if (StaffAuthEmail.looksLikeStaffNumberOnly(raw)) return null;
    if (skipsVerification(raw)) return null;
    return validateFormat(raw);
  }
}
