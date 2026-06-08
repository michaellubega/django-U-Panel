import 'package:shared_preferences/shared_preferences.dart';

import '../auth/student_registration_number.dart';

/// Legacy local lock for one student per install. No longer enforced at login;
/// proxy prevention is per session at check-in instead.
class DeviceStudentRegistrationLock {
  DeviceStudentRegistrationLock._();

  static const _prefsKey = 'u_panel_device_student_reg_lock_v1';

  static const String blockMessage =
      'This device already registered another student. '
      'Each phone may only be used for one student.';

  static Future<String?> lockedRegistrationNormalized() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey)?.trim();
    if (raw == null || raw.isEmpty) return null;
    return StudentRegistrationNumber.normalize(raw);
  }

  /// Non-null when [registrationNumber] must not proceed on this device.
  static Future<String?> blockReasonFor(String registrationNumber) async {
    final reg = StudentRegistrationNumber.normalize(registrationNumber);
    if (reg.isEmpty) return null;
    final locked = await lockedRegistrationNormalized();
    if (locked == null || locked.isEmpty) return null;
    if (locked == reg) return null;
    return blockMessage;
  }

  /// Records the first registration number used on this install.
  static Future<void> bindRegistration(String registrationNumber) async {
    final reg = StudentRegistrationNumber.normalize(registrationNumber);
    if (reg.isEmpty) return;
    final locked = await lockedRegistrationNormalized();
    if (locked != null && locked.isNotEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, reg);
  }

  /// Clears a stale lock (e.g. after sign-out on a shared phone).
  static Future<void> clearOnSignOut() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_prefsKey);
  }

  /// Tests only.
  static Future<void> clearForTest() => clearOnSignOut();
}
