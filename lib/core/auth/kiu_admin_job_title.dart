/// Optional job title for KIU administrators (e.g. DIRECTOR QUALITY ASSURANCE).
abstract final class KiuAdminJobTitle {
  static const examplesLine =
      'Examples: DIRECTOR QUALITY ASSURANCE, DIRECTOR FINANCE';

  /// Returns uppercase trimmed title, or null when empty.
  static String? normalize(String? raw) {
    final t = raw?.trim();
    if (t == null || t.isEmpty) return null;
    return t.toUpperCase();
  }
}
