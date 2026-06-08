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
}
