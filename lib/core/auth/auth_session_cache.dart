import 'dart:convert';

import '../storage/attendance_local_queues.dart';
import '../storage/local_json_decode.dart';

const _storageKey = 'auth_session_cache_v1';

/// Last-known profile + role flags for a signed-in uid (device-local).
class AuthSessionSnapshot {
  const AuthSessionSnapshot({
    required this.uid,
    this.registrationNumber,
    this.fullName,
    this.kiuAdminJobTitle,
    this.kiuAdminOnboardingComplete = false,
    this.isAdmin = false,
    this.isQaStaff = false,
    this.isKiuAdmin = false,
    this.isLecturer = false,
    this.staffNumber,
  });

  final String uid;
  final String? registrationNumber;
  final String? fullName;
  final String? kiuAdminJobTitle;
  final bool kiuAdminOnboardingComplete;
  final bool isAdmin;
  final bool isQaStaff;
  final bool isKiuAdmin;
  final bool isLecturer;
  final String? staffNumber;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'uid': uid,
        if (registrationNumber != null) 'registrationNumber': registrationNumber,
        if (fullName != null) 'fullName': fullName,
        if (kiuAdminJobTitle != null) 'kiuAdminJobTitle': kiuAdminJobTitle,
        'kiuAdminOnboardingComplete': kiuAdminOnboardingComplete,
        'isAdmin': isAdmin,
        'isQaStaff': isQaStaff,
        'isKiuAdmin': isKiuAdmin,
        'isLecturer': isLecturer,
        if (staffNumber != null) 'staffNumber': staffNumber,
      };

  static AuthSessionSnapshot? fromJson(Map<String, dynamic> json) {
    final uid = (json['uid'] as String?)?.trim();
    if (uid == null || uid.isEmpty) return null;
    String? text(String key) {
      final v = (json[key] as String?)?.trim();
      return (v != null && v.isNotEmpty) ? v : null;
    }

    bool flag(String key) =>
        json[key] == true || json[key] == 'true' || json[key] == 1;

    return AuthSessionSnapshot(
      uid: uid,
      registrationNumber: text('registrationNumber'),
      fullName: text('fullName'),
      kiuAdminJobTitle: text('kiuAdminJobTitle'),
      kiuAdminOnboardingComplete: flag('kiuAdminOnboardingComplete'),
      isAdmin: flag('isAdmin'),
      isQaStaff: flag('isQaStaff'),
      isKiuAdmin: flag('isKiuAdmin'),
      isLecturer: flag('isLecturer'),
      staffNumber: text('staffNumber'),
    );
  }
}

/// Persists [AuthSessionSnapshot] so repeat logins can route instantly.
abstract final class AuthSessionCache {
  AuthSessionCache._();

  /// Fast path for web boot — any persisted session (uid not validated here).
  static Future<bool> hasAnyCachedSession() async {
    final raw = await AttendanceLocalQueues.readString(_storageKey);
    return raw != null && raw.trim().isNotEmpty;
  }

  static Future<AuthSessionSnapshot?> load(String uid) async {
    final id = uid.trim();
    if (id.isEmpty) return null;
    final raw = await AttendanceLocalQueues.readString(_storageKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = await decodeStoredJson<Map<String, dynamic>>(
      raw: raw,
      storageKey: _storageKey,
      removeKey: AttendanceLocalQueues.removeKey,
      parse: (value) => value is Map ? Map<String, dynamic>.from(value) : {},
      debugLabel: 'AuthSessionCache',
    );
    if (decoded == null || decoded.isEmpty) return null;
    final snap = AuthSessionSnapshot.fromJson(decoded);
    if (snap == null || snap.uid != id) return null;
    return snap;
  }

  static Future<void> save(AuthSessionSnapshot snapshot) async {
    final uid = snapshot.uid.trim();
    if (uid.isEmpty) return;
    await AttendanceLocalQueues.writeString(
      _storageKey,
      jsonEncode(snapshot.toJson()),
    );
  }

  static Future<void> clear() async {
    await AttendanceLocalQueues.removeKey(_storageKey);
  }
}
