/// KIU administrator registration number (e.g. KIU4235S).
abstract final class KiuAdminRegistrationNumber {
  static const example = 'KIU4235S';

  static final _pattern = RegExp(r'^KIU\d+[A-Z]$');

  static String normalize(String raw) => raw.trim().toUpperCase();

  static String? validateFormat(String raw) {
    final reg = normalize(raw);
    if (reg.isEmpty) return 'Enter your KIU administrator registration number.';
    if (!_pattern.hasMatch(reg)) {
      return 'Registration number must look like $example '
          '(KIU, digits, then one letter).';
    }
    return null;
  }

  /// True when [raw] is only a KIU staff registration id (no @), e.g. KIU4235S.
  static bool looksLikeRegistrationNumberOnly(String raw) {
    final t = raw.trim();
    if (t.isEmpty || t.contains('@')) return false;
    return validateFormat(t) == null;
  }
}
