import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../features/notices/data/notices_repository.dart';
import '../api/api_auth.dart';
import '../api/api_client.dart';
import '../api/api_collections.dart';
import '../api/api_config.dart';
import '../api/api_exceptions.dart';
import '../api/api_field_value.dart';
import '../api/api_store.dart';
import '../platform/web_fast_boot.dart';
import 'auth_action_result.dart';
import 'auth_session_cache.dart';
import 'kiu_admin_registration_number.dart';
import 'kiu_staff_auth_email.dart';
import 'lecturer_registration_number.dart';
import 'staff_auth_email.dart';
import 'student_auth_email.dart';
import 'student_registration_number.dart';
import 'kiu_admin_job_title.dart';
import 'login_email.dart';
import 'user_role.dart';
import '../connectivity/app_connectivity.dart';
import '../errors/user_facing_errors.dart';
import '../storage/attendance_local_queues.dart';
import '../navigation/app_navigator.dart';
import '../session/app_session_reset.dart';
import '../storage/staff_number_directory_cache.dart';

/// Result of [AuthRepository.registerLecturerAccount] / [registerQaStaffAccount].
typedef StaffRegistrationResult = ({String? error, String? staffNumber});

/// Web (JS interop) often wraps the real [ApiException] on `error`.
ApiException? _unwrapApiException(Object e) {
  if (e is ApiException) return e;
  try {
    final dynamic boxed = e;
    final inner = boxed.error;
    if (inner is ApiException) return inner;
  } catch (_) {}
  return null;
}

/// Web (JS interop) often boxes the real Dart exception on `error`.
_StudentRegConflict? _studentRegConflictFromError(Object e) {
  if (e is _StudentRegConflict) return e;
  try {
    final dynamic boxed = e;
    final inner = boxed.error;
    if (inner is _StudentRegConflict) return inner;
    if (inner != null) {
      return _studentRegConflictFromError(inner as Object);
    }
  } catch (_) {}
  return null;
}

String? _extractBoxedJsError(Object e) {
  try {
    final dynamic boxed = e;
    final code = boxed.code;
    final message = boxed.message;
    final error = boxed.error;
    final stack = boxed.stack;
    final parts = <String>[];
    if (code != null) parts.add('code=$code');
    if (message != null) parts.add('message=$message');
    if (error != null) parts.add('error=$error');
    if (stack != null) parts.add('stack=$stack');
    if (parts.isNotEmpty) return parts.join(' | ');
  } catch (_) {}
  return null;
}

String _formatApiFailure(Object e) {
  final fe = _unwrapApiException(e);
  if (fe != null) {
    return '${fe.code}: ${fe.message ?? fe.toString()}';
  }
  final boxed = _extractBoxedJsError(e);
  if (boxed != null && boxed.trim().isNotEmpty) {
    return boxed;
  }
  try {
    final dynamic boxed = e;
    final code = boxed.code;
    final message = boxed.message;
    if (code is String || message is String) {
      final c = (code is String && code.trim().isNotEmpty)
          ? code.trim()
          : 'unknown';
      final m = (message is String && message.trim().isNotEmpty)
          ? message.trim()
          : e.toString();
      return '$c: $m';
    }
  } catch (_) {}
  return e.toString();
}

bool _isApiPermissionDenied(Object e) {
  final fe = _unwrapApiException(e);
  if (fe != null) return fe.code == 'permission-denied';
  try {
    final dynamic boxed = e;
    final code = boxed.code;
    if (code is String) return code == 'permission-denied';
  } catch (_) {}
  final raw = e.toString().toLowerCase();
  final boxed = _extractBoxedJsError(e)?.toLowerCase() ?? '';
  if (boxed.contains('permission-denied')) return true;
  if (boxed.contains('missing or insufficient permissions')) return true;
  if (raw.contains('permission-denied')) return true;
  if (raw.contains('missing or insufficient permissions')) return true;
  return false;
}

String _formatStaffWriteFailure({
  required String stage,
  required Object error,
  required String databaseId,
  required String? currentUid,
}) {
  final detail = _formatApiFailure(error);
  final uidPart = (currentUid != null && currentUid.trim().isNotEmpty)
      ? currentUid.trim()
      : 'unknown uid';
  if (_isApiPermissionDenied(error)) {
    return UserFacingErrors.forPermissionDenied();
  }
  if (kDebugMode) {
    debugPrint(
      'AuthRepository staff write failed at $stage '
      '(db=$databaseId, uid=$uidPart): $detail',
    );
  }
  return UserFacingErrors.genericTryAgain;
}

/// Django API auth (email + password) with optional profile fields in [app_users/{uid}].
/// Admin role: [admins] / document id = API user id, field [adminIsAdminField].
/// Lecturer role: [lecturers] / document id = API user id, field [lecturerIsLecturerField].
class AuthRepository extends ChangeNotifier {
  AuthRepository._();
  static final AuthRepository instance = AuthRepository._();

  static const adminIsAdminField = 'isAdmin';
  static const adminIsAdminLegacyField = 'isadmin';

  /// Distinguishes QA staff from full administrators in the UI ([admins] collection).
  static const adminRoleField = 'adminRole';
  static const kiuAdminJobTitleField = 'kiuAdminJobTitle';
  static const adminRoleQaStaff = 'qa_staff';
  static const adminRoleAdministrator = 'administrator';
  static const adminIsKiuAdminField = 'isKiuAdmin';
  static const kiuAdminOnboardingCompleteField = 'kiuAdminOnboardingComplete';
  static const staffAccountRoleField = 'staffAccountRole';
  static const staffAccountRoleKiuAdministrator = 'kiu_administrator';
  static const staffAccountRoleStaff = 'staff';
  static const lecturerIsLecturerField = 'isLecturer';

  /// Student role on [ApiCollections.appUsers] — used for UI routing.
  static const appUserIsStudentField = 'isStudent';

  static const pendingRegistrationNumberField = 'pendingRegistrationNumber';
  /// Set on [student_registrations] only after API auth email is verified.
  static const studentRegEmailVerifiedLinkField = 'emailVerifiedAtLink';

  static bool _studentRegistrationLockIsFinal(Map<String, dynamic>? data) {
    if (data == null) return false;
    return data[studentRegEmailVerifiedLinkField] == true;
  }

  static bool _adminFlagFromData(Map<String, dynamic>? data) {
    if (data == null) return false;
    bool truthy(dynamic v) => v == true || v == 'true' || v == 1;
    if (truthy(data[adminIsAdminField]) || truthy(data[adminIsAdminLegacyField])) {
      return true;
    }
    final role = (data[adminRoleField] as String?)?.trim().toLowerCase();
    if (role == adminRoleQaStaff || role == adminRoleAdministrator) {
      return true;
    }
    return _adminDocIsQaStaff(data);
  }

  static bool _kiuAdminFlagFromData(Map<String, dynamic>? data) {
    if (data == null) return false;
    bool truthy(dynamic v) => v == true || v == 'true' || v == 1;
    return truthy(data[adminIsKiuAdminField]);
  }

  Future<ApiDocumentSnapshot?> _safeRoleDocGet(
    ApiDocRef ref,
  ) async {
    try {
      return await ref.get();
    } catch (_) {
      return null;
    }
  }

  /// Reads [admins/{uid}] and legacy [admin/{uid}], preferring whichever grants admin.
  Future<ApiDocumentSnapshot> _fetchAdminRoleDoc(String uid) async {
    final db = apiStore();
    final snaps = await Future.wait<ApiDocumentSnapshot?>([
      _safeRoleDocGet(db.collection(ApiCollections.admins).doc(uid)),
      _safeRoleDocGet(db.collection(ApiCollections.adminsLegacy).doc(uid)),
    ]);
    final primary = snaps[0];
    final legacy = snaps[1];

    if (primary != null) {
      final primaryAdmin = primary.exists && _adminFlagFromData(primary.data());
      if (primaryAdmin) return primary;
    }
    if (legacy != null) {
      final legacyAdmin = legacy.exists && _adminFlagFromData(legacy.data());
      if (legacyAdmin) return legacy;
      if (legacy.exists) return legacy;
    }
    if (primary != null && primary.exists) return primary;
    if (primary != null) return primary;
    if (legacy != null) return legacy;
    return db.collection(ApiCollections.admins).doc(uid).get();
  }

  

  bool _initialized = false;
  bool get initialized => _initialized;

  /// Cached session exists but API auth has not confirmed the user yet
  /// (web fast boot, native cold start, or auth persistence still loading).
  bool _pendingWebSessionRestore = false;
  bool get pendingWebSessionRestore => _pendingWebSessionRestore;
  bool _forceSignedOut = false;
  bool _signingOut = false;
  bool _changingPassword = false;
  int _authenticatingCount = 0;
  int _sessionEpoch = 0;
  bool _verificationEmailQueuedAtSignup = false;

  /// True while sign-in or registration is in flight (avoids login-screen flash).
  bool get isAuthenticating => _authenticatingCount > 0;

  /// Set after register API queues the first verification email (skip auto-resend).
  bool get verificationEmailQueuedAtSignup => _verificationEmailQueuedAtSignup;

  void markVerificationEmailQueuedAtSignup() {
    _verificationEmailQueuedAtSignup = true;
  }

  void clearVerificationEmailQueuedAtSignup() {
    _verificationEmailQueuedAtSignup = false;
  }

  /// True while [logout] is waiting for the API — UI shows a blocking overlay.
  bool get signingOut => _signingOut;

  /// Changes on each sign-out so [AppShell] and tabs are recreated for the next login.
  int get sessionEpoch => _sessionEpoch;

  String? _cachedReg;

  /// `true` / `false` from [app_users]; `null` = legacy doc without [appUserIsStudentField].
  bool? _cachedIsStudentProfile;
  String? _cachedName;
  String? _cachedKiuAdminJobTitle;
  String? _cachedEmail;
  bool _isAdmin = false;
  bool _isQaStaff = false;
  bool _isKiuAdmin = false;
  bool _kiuAdminOnboardingComplete = false;
  bool _adminCheckDone = false;

  bool _isLecturer = false;
  bool _lecturerCheckDone = false;
  String? _cachedStaffNumber;

  /// True when reading [admins] / [lecturers] failed with permission-denied (rules not deployed, wrong DB, etc.).
  bool _apiRoleCheckDenied = false;

  /// Skips repeat role reads when [authStateChanges] fires many times for the same uid.
  String? _lastRoleHydrateUid;

  int _hydrateGeneration = 0;
  Future<void>? _activeHydrate;
  String? _activeHydrateUid;
  String? _lastAuthStateUid;

  Future<void>? _registrationHydrateInFlight;
  DateTime? _lastRegistrationHydrateAttemptAt;
  static const Duration _registrationHydrateCooldown = Duration(minutes: 5);

  static bool _loggedRoleRulesDeployHint = false;

  StreamSubscription<ApiUser?>? _authSub;

  /// API [admins] with `isAdmin: true` (QA staff and full administrators).
  bool get isAdmin => _isAdmin;

  /// KIU administrator — campus check-in required; not QA operational staff.
  bool get isKiuAdmin => _isKiuAdmin;

  /// QA staff: same privileges as [isAdmin], different [resolvedRole] / UI label.
  bool get isQaStaff => _isQaStaff;

  /// Full administrator (not QA staff).
  bool get isFullAdministrator => isAdmin && !isQaStaff;

  bool get adminCheckDone => _adminCheckDone;

  bool get isLecturer => _isLecturer;
  bool get lecturerCheckDone => _lecturerCheckDone;

  /// Signed in with a KIU staff mailbox (@kiu.ac.ug etc.), not a student domain.
  bool get isStaffAuthIdentity {
    if (!isLoggedIn) return false;
    final email =
        ApiAuth.instance.currentUser?.email ?? _cachedEmail ?? '';
    return KiuStaffAuthEmail.isStaffMailbox(email);
  }

  /// Signed in with synthetic `KIU-####` staff ID (QA staff / administrators).
  bool get isSyntheticStaffAuthIdentity {
    if (!isLoggedIn) return false;
    final email =
        ApiAuth.instance.currentUser?.email ?? _cachedEmail ?? '';
    return StaffAuthEmail.syntheticEmailToStaffNumber(email) != null;
  }

  /// Signed in with a student mailbox (@studmc.kiu.ac.ug or @studwc.kiu.ac.ug).
  bool get isStudentAuthIdentity {
    if (!isLoggedIn) return false;
    if (isStaffAuthIdentity) return false;
    if (isSyntheticStaffAuthIdentity) return false;
    final email =
        ApiAuth.instance.currentUser?.email ?? _cachedEmail ?? '';
    return StudentAuthEmail.isStudentMailbox(email);
  }

  /// Before role hydration: KIU student mailbox and not staff / explicitly non-student.
  bool get isLikelyStudent {
    if (isSyntheticStaffAuthIdentity) return false;
    if (!isStudentAuthIdentity) return false;
    if (_cachedIsStudentProfile == false) return false;
    if (adminCheckDone && (_isAdmin || _isKiuAdmin)) return false;
    if (lecturerCheckDone && _isLecturer) return false;
    return true;
  }

  /// True when student UI and student-scoped attendance loads should run.
  bool get isStudentProfile {
    if (!isLoggedIn) return false;
    if (isSyntheticStaffAuthIdentity || isStaffAuthIdentity) return false;
    if (_isAdmin || _isQaStaff || _isKiuAdmin || _isLecturer) return false;
    if (_adminCheckDone && (_isAdmin || _isKiuAdmin)) return false;
    if (_lecturerCheckDone && _isLecturer) return false;
    if (!isStudentAuthIdentity) return false;
    if (_cachedIsStudentProfile == false) return false;
    return _cachedIsStudentProfile ?? true;
  }

  /// Resolved role for navigation: API grants (admins / lecturers) win.
  UserRole get resolvedRole {
    if (_adminCheckDone && _isAdmin) {
      return _isQaStaff ? UserRole.qaStaff : UserRole.admin;
    }
    if (_adminCheckDone && _isKiuAdmin) return UserRole.kiuAdmin;
    // Trust cached/hydrated flags before role reads finish (session restore).
    if (_isQaStaff) return UserRole.qaStaff;
    if (_isAdmin) return UserRole.admin;
    if (_isKiuAdmin) return UserRole.kiuAdmin;
    if (_isLecturer) return UserRole.lecturer;
    if (isStaffAuthIdentity || isSyntheticStaffAuthIdentity) {
      return UserRole.lecturer;
    }
    if (isStudentAuthIdentity || isStudentProfile) return UserRole.student;
    return UserRole.lecturer;
  }

  static bool? parseIsStudentFromProfileData(Map<String, dynamic>? data) {
    if (data == null || !data.containsKey(appUserIsStudentField)) return null;
    return data[appUserIsStudentField] == true;
  }

  /// Prefer [app_users.email], but fall back to API auth when the doc field
  /// is missing or blank (legacy rows often omit it).
  String _profileEmailFromData(Map<String, dynamic> data, ApiUser user) {
    final fromDoc = (data['email'] as String?)?.trim().toLowerCase() ?? '';
    if (fromDoc.isNotEmpty) return fromDoc;
    return (user.email ?? _cachedEmail ?? '').trim().toLowerCase();
  }

  String _authMailboxEmail(ApiUser user) =>
      (user.email ?? _cachedEmail ?? '').trim().toLowerCase();

  bool _isStudentAccountProfile(Map<String, dynamic> data, ApiUser user) {
    if (parseIsStudentFromProfileData(data) == true) return true;
    if (parseIsStudentFromProfileData(data) == false) {
      return StudentAuthEmail.isStudentMailbox(_authMailboxEmail(user));
    }
    if (StudentAuthEmail.isStudentMailbox(_profileEmailFromData(data, user))) {
      return true;
    }
    return StudentAuthEmail.isStudentMailbox(_authMailboxEmail(user));
  }

  void _applyIsStudentFromProfileData(
    Map<String, dynamic>? data,
    ApiUser user,
  ) {
    final authEmail = _authMailboxEmail(user);
    if (StaffAuthEmail.syntheticEmailToStaffNumber(authEmail) != null ||
        KiuStaffAuthEmail.isStaffMailbox(authEmail)) {
      _cachedIsStudentProfile = false;
      return;
    }
    if (data != null && _isStudentAccountProfile(data, user)) {
      final explicit = parseIsStudentFromProfileData(data);
      _cachedIsStudentProfile = explicit ?? true;
      return;
    }
    final explicit = parseIsStudentFromProfileData(data);
    if (explicit != null) {
      _cachedIsStudentProfile = explicit;
      return;
    }
    final profileEmail = data == null
        ? _authMailboxEmail(user)
        : _profileEmailFromData(data, user);
    _cachedIsStudentProfile =
        StudentAuthEmail.isStudentMailbox(profileEmail) ? null : false;
  }

  void _applyStudentRegistrationFromProfileData(
    Map<String, dynamic> data,
    ApiUser user,
  ) {
    final pending =
        (data[pendingRegistrationNumberField] as String?)?.trim();
    if (user.emailVerified) {
      final regToLink = _studentRegistrationFromProfile(data);
      _cachedReg = regToLink != null && regToLink.isNotEmpty
          ? StudentRegistrationNumber.normalize(regToLink)
          : null;
      return;
    }
    _cachedReg = (pending != null && pending.isNotEmpty)
        ? StudentRegistrationNumber.normalize(pending)
        : null;
  }

  void _recoverStudentRegistrationIfNeeded(
    ApiUser user, {
    Map<String, dynamic>? profileData,
  }) {
    if (!_isStudentAccountProfile(profileData ?? {}, user) &&
        !StudentAuthEmail.isStudentMailbox(_authMailboxEmail(user))) {
      return;
    }
    if (_cachedReg?.trim().isNotEmpty == true) return;
    if (profileData != null) {
      final reg = _studentRegistrationFromProfile(profileData);
      if (reg != null && reg.isNotEmpty) {
        _cachedReg = StudentRegistrationNumber.normalize(reg);
      }
    }
    if (_cachedIsStudentProfile == false &&
        (_cachedReg?.trim().isNotEmpty == true ||
            parseIsStudentFromProfileData(profileData) == true)) {
      _cachedIsStudentProfile = true;
    }
  }

  String? _registrationFromStudentRegDoc(
    ApiDocumentSnapshot doc,
  ) {
    final data = doc.data();
    final fromField = (data?['registrationNumber'] as String?)?.trim();
    if (fromField != null && fromField.isNotEmpty) {
      return StudentRegistrationNumber.normalize(fromField);
    }
    final id = doc.id.trim();
    if (StudentRegistrationNumber.isCanonicalFormat(id)) {
      return StudentRegistrationNumber.normalize(id);
    }
    return null;
  }

  String? _registrationFromOwnedStudentRegDoc(
    ApiDocumentSnapshot doc,
    ApiUser user,
  ) {
    if (!doc.exists) return null;
    final data = doc.data();
    if (data == null) return null;
    final ownerUid = (data['uid'] as String?)?.trim() ?? '';
    if (ownerUid.isNotEmpty && ownerUid != user.uid.trim()) return null;
    final em = StudentAuthEmail.normalizeStudentEmail(user.email ?? '');
    final docEmail =
        StudentAuthEmail.normalizeStudentEmail((data['email'] as String?) ?? '');
    if (docEmail.isNotEmpty && em.isNotEmpty && docEmail != em) return null;
    return _registrationFromStudentRegDoc(doc);
  }

  /// Authoritative link: [student_registrations] rows keyed by uid + school email.
  Future<String?> _lookupStudentRegistrationFromEmailLink(
    ApiUser user, {
    String? registrationHint,
  }) async {
    if (!StudentAuthEmail.isStudentMailbox(user.email ?? '')) return null;
    if (_skipServerRegistrationVerification()) return null;
    final uid = user.uid.trim();
    if (uid.isEmpty) return null;
    final em = StudentAuthEmail.normalizeStudentEmail(user.email ?? '');

    try {
      final db = apiStore();
      final hinted = registrationHint?.trim();
      if (hinted != null && hinted.isNotEmpty) {
        final reg = StudentRegistrationNumber.normalize(hinted);
        if (reg.isNotEmpty) {
          final direct = await db
              .collection(ApiCollections.studentRegistrations)
              .doc(reg)
              .get();
          final owned = _registrationFromOwnedStudentRegDoc(direct, user);
          if (owned != null && owned.isNotEmpty) {
            return owned;
          }
        }
      }

      String? pending;

      final byUid = await db
          .collection(ApiCollections.studentRegistrations)
          .where('uid', isEqualTo: uid)
          .limit(10)
          .get();
      for (final doc in byUid.docs) {
        final reg = _registrationFromStudentRegDoc(doc);
        if (reg == null) continue;
        final data = doc.data();
        final docEmail = StudentAuthEmail.normalizeStudentEmail(
          (data?['email'] as String?) ?? '',
        );
        if (em.isNotEmpty && docEmail.isNotEmpty && docEmail != em) continue;
        if (_studentRegistrationLockIsFinal(data) || user.emailVerified) {
          return reg;
        }
        pending ??= reg;
      }
      if (pending != null) return pending;

      if (em.isEmpty) return null;
      final byEmail = await db
          .collection(ApiCollections.studentRegistrations)
          .where('email', isEqualTo: em)
          .limit(10)
          .get();
      for (final doc in byEmail.docs) {
        final data = doc.data();
        final ownerUid = (data?['uid'] as String?)?.trim() ?? '';
        if (ownerUid.isNotEmpty && ownerUid != uid) continue;
        final reg = _registrationFromStudentRegDoc(doc);
        if (reg == null) continue;
        if (_studentRegistrationLockIsFinal(data) || user.emailVerified) {
          return reg;
        }
        pending ??= reg;
      }
      return pending;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AuthRepository._lookupStudentRegistrationFromEmailLink: $e');
        debugPrint('$st');
      }
      return null;
    }
  }

  Future<void> _backfillAppUserRegistrationFromEmailLink(
    ApiUser user,
    String reg, {
    Map<String, dynamic>? profileData,
  }) async {
    if (_skipServerRegistrationVerification()) return;
    final normalized = StudentRegistrationNumber.normalize(reg);
    if (normalized.isEmpty) return;
    final existing = profileData != null
        ? _studentRegistrationFromProfile(profileData)
        : _cachedReg;
    if (existing != null &&
        StudentRegistrationNumber.normalize(existing) == normalized) {
      return;
    }
    try {
      await apiStore()
          .collection(ApiCollections.appUsers)
          .doc(user.uid)
          .set(
        <String, dynamic>{
          'email': StudentAuthEmail.normalizeStudentEmail(user.email ?? ''),
          'registrationNumber': normalized,
          pendingRegistrationNumberField: ApiFieldValue.delete(),
          appUserIsStudentField: true,
          'updatedAt': ApiFieldValue.serverTimestamp(),
        },
        ApiSetOptions(merge: true),
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AuthRepository._backfillAppUserRegistrationFromEmailLink: $e');
        debugPrint('$st');
      }
    }
  }

  /// Profile fields first, then [student_registrations] by uid / attached school email.
  Future<void> _recoverStudentRegistrationFromAttachedEmail(
    ApiUser user, {
    Map<String, dynamic>? profileData,
    required int hydrateGeneration,
  }) async {
    _recoverStudentRegistrationIfNeeded(user, profileData: profileData);
    if (_cachedReg?.trim().isNotEmpty == true) return;
    if (_skipServerRegistrationVerification()) {
      await _applyCachedRegistrationWhenOffline(user);
      return;
    }
    if (!StudentAuthEmail.isStudentMailbox(_authMailboxEmail(user))) return;

    final hint = profileData != null
        ? _studentRegistrationFromProfile(profileData)
        : _cachedReg;
    final fromLink = await _lookupStudentRegistrationFromEmailLink(
      user,
      registrationHint: hint,
    );
    if (fromLink == null || fromLink.isEmpty) return;
    if (hydrateGeneration != _hydrateGeneration) return;

    _cachedReg = StudentRegistrationNumber.normalize(fromLink);
    _cachedIsStudentProfile = true;
    await _backfillAppUserRegistrationFromEmailLink(
      user,
      fromLink,
      profileData: profileData,
    );
    if (hydrateGeneration == _hydrateGeneration) {
      unawaited(_persistSessionCache(user.uid));
      notifyListeners();
    }
  }

  Future<void> _backfillAppUserIsStudentFlag(String uid) async {
    if (!isStudentAuthIdentity) return;
    if (_cachedIsStudentProfile == true) return;
    try {
      await apiStore().collection(ApiCollections.appUsers).doc(uid).set(
        <String, dynamic>{
          appUserIsStudentField: true,
          'updatedAt': ApiFieldValue.serverTimestamp(),
        },
        ApiSetOptions(merge: true),
      );
      _cachedIsStudentProfile = true;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AuthRepository._backfillAppUserIsStudentFlag: $e');
        debugPrint('$st');
      }
    }
  }

  /// Lecturer attendance tools (lists / sessions) for lecturers and KIU administrators.
  bool get hasLecturerAttendanceAccess =>
      !isStudentAuthIdentity &&
      ((_lecturerCheckDone && _isLecturer && !_isAdmin) ||
          (_adminCheckDone && _isKiuAdmin));

  /// Student mailboxes must never retain staff role flags (device cache or API).
  void _stripStaffRolesForStudentMailbox() {
    if (!isStudentAuthIdentity) return;
    // API-granted staff access always wins over a student-domain mailbox.
    if (_isAdmin || _isQaStaff || _isKiuAdmin || _isLecturer) {
      _cachedIsStudentProfile = false;
      return;
    }
    _isAdmin = false;
    _isQaStaff = false;
    _isKiuAdmin = false;
    _isLecturer = false;
    _cachedStaffNumber = null;
    _cachedIsStudentProfile = true;
  }

  static bool _adminDocIsQaStaff(Map<String, dynamic>? data) {
    if (data == null) return false;
    final role = (data[adminRoleField] as String?)?.trim().toLowerCase();
    if (role == adminRoleQaStaff) return true;
    if (role == adminRoleAdministrator) return false;
    final sn = (data['staffNumber'] as String?)?.trim();
    if (sn != null &&
        sn.isNotEmpty &&
        StaffAuthEmail.normalizeStaffNumber(sn) != null) {
      return true;
    }
    return false;
  }

  /// QA staff rows in [ApiCollections.admins].
  static bool adminDocIsQaStaff(Map<String, dynamic>? data) =>
      _adminDocIsQaStaff(data);

  /// Full administrator rows in [ApiCollections.admins] (not QA staff).
  static bool adminDocIsFullAdministrator(Map<String, dynamic> data) =>
      _adminFlagFromData(data) && !_adminDocIsQaStaff(data);

  /// True when role flags have been loaded at least once.
  bool get roleCheckDone => _adminCheckDone && _lecturerCheckDone;

  /// Set when the API denied role profile reads (permissions / backend config).
  bool get apiRoleCheckDenied => _apiRoleCheckDenied;

  String? _authFormErrorMessage;

  /// Draft sign-up fields retained until success or explicit sign-out.
  String _draftEmail = '';
  String _draftFullName = '';
  String _draftRegistrationNumber = '';
  bool _draftRegisterMode = false;

  void updateAuthFormDraft({
    required String email,
    required String fullName,
    required String registrationNumber,
    required bool registering,
  }) {
    _draftEmail = email;
    _draftFullName = fullName;
    _draftRegistrationNumber = registrationNumber;
    _draftRegisterMode = registering;
  }

  void clearAuthFormDraft() {
    _draftEmail = '';
    _draftFullName = '';
    _draftRegistrationNumber = '';
    _draftRegisterMode = false;
  }

  ({String email, String fullName, String registrationNumber, bool registering})
      get authFormDraft => (
        email: _draftEmail,
        fullName: _draftFullName,
        registrationNumber: _draftRegistrationNumber,
        registering: _draftRegisterMode,
      );

  /// Persistent login / registration error for [AuthScreen] (survives widget rebuilds).
  String? get authFormErrorMessage => _authFormErrorMessage;

  /// Set when [app_users] registration number conflicts with [student_registrations].
  String? get studentRegistrationConflictMessage => _authFormErrorMessage;

  void presentAuthFormError(String message) {
    final text = message.trim();
    if (text.isEmpty) return;
    if (_authFormErrorMessage == text) {
      if (isLoggedIn && !isAuthenticating) {
        showRootSnackBar(text, isError: true, duration: const Duration(seconds: 6));
      }
      return;
    }
    _authFormErrorMessage = text;
    notifyListeners();
    if (isLoggedIn && !isAuthenticating) {
      showRootSnackBar(text, isError: true, duration: const Duration(seconds: 6));
    }
  }

  void _presentStudentRegistrationConflict(String message) {
    presentAuthFormError(message);
  }

  void clearAuthFormError() {
    if (_authFormErrorMessage == null) return;
    _authFormErrorMessage = null;
    notifyListeners();
  }

  void clearStudentRegistrationConflictMessage() => clearAuthFormError();

  AuthActionResult _authActionError(String message) {
    presentAuthFormError(message);
    return AuthActionResult(error: message);
  }

  void _applyStaffNumberFromData(Map<String, dynamic>? data) {
    if (data == null) return;
    final sn = (data['staffNumber'] as String?)?.trim().toUpperCase();
    if (sn != null && sn.isNotEmpty) {
      _cachedStaffNumber = sn;
      return;
    }
    final reg = (data['registrationNumber'] as String?)?.trim().toUpperCase();
    if (reg != null && reg.isNotEmpty) {
      _cachedStaffNumber = reg;
    }
  }

  /// KIU-#### logins use a synthetic staff email — derive the display id when
  /// API profile rows omit [staffNumber].
  void _ensureCachedStaffNumberFromAuthEmail(String? email) {
    if (_cachedStaffNumber?.trim().isNotEmpty == true) return;
    final fromEmail = StaffAuthEmail.syntheticEmailToStaffNumber(email ?? '');
    if (fromEmail != null) {
      _cachedStaffNumber = fromEmail.toUpperCase();
    }
  }

  bool _hasCachedStaffIdentity() =>
      _cachedStaffNumber != null && _cachedStaffNumber!.trim().isNotEmpty;

  /// True when cached profile has the ids needed for attendance routing.
  bool _identityHydrationComplete(ApiUser user) {
    final email = user.email ?? _cachedEmail ?? '';
    if (StudentAuthEmail.isStudentMailbox(email)) {
      return _cachedReg != null && _cachedReg!.trim().isNotEmpty;
    }
    if (!_adminCheckDone || !_lecturerCheckDone) return false;
    if (_isAdmin || _isQaStaff || _isKiuAdmin || _isLecturer) {
      return _hasCachedStaffIdentity();
    }
    if (KiuStaffAuthEmail.isStaffMailbox(email)) {
      return false;
    }
    if (StaffAuthEmail.syntheticEmailToStaffNumber(email) != null) {
      return false;
    }
    return true;
  }

  /// KIU-#### for signed-in lecturer; null for other users.
  String? get currentStaffNumber => _cachedStaffNumber;

  /// API user id for the signed-in user (for admin grants).
  String? get currentUserId =>
      _apiReady ? ApiAuth.instance.currentUser?.uid : null;

  bool get _apiReady {
    return isApiConfigured && ApiClient.instance.isLoaded;
  }

  String _apiNotReadyMessage() {
    if (!kIsWeb) {
      switch (defaultTargetPlatform) {
        case TargetPlatform.windows:
        case TargetPlatform.linux:
        case TargetPlatform.macOS:
          return UserFacingErrors.backendNotReadyDesktop;
        default:
          break;
      }
    }
    return 'The Django backend is not ready. Check $uPanelApiBaseUrl and try again.';
  }

  static String _normalizeReg(String reg) => reg.trim().toUpperCase();

  /// Strips invisible chars and mistaken leading `|` so email/password auth does not fail oddly.
  static String normalizeEmail(String raw) {
    var s = raw.trim();
    s = s.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF\u2060\u200E\u200F]'), '');
    s = s.replaceAll(RegExp(r'^[|\uFF5C\u007C\u00A0\s]+'), '');
    return s.trim();
  }

  static const String networkUnavailableMessage =
      UserFacingErrors.networkUnavailable;

  /// True when server-side registration lock checks must be deferred.
  bool _skipServerRegistrationVerification() {
    return AppConnectivity.instance.initialized &&
        !AppConnectivity.instance.isOnline;
  }

  Map<String, String> _cachedProfileMapForUser(ApiUser user) {
    final email = _uiVisibleEmail(user.email) ?? '—';
    final reg = _cachedReg?.trim();
    return {
      'email': email,
      'registrationNumber':
          reg != null && reg.isNotEmpty ? reg.toUpperCase() : '—',
      if (_cachedName != null && _cachedName!.trim().isNotEmpty)
        'fullName': _cachedName!.trim(),
    };
  }

  Future<void> _applyCachedRegistrationWhenOffline(ApiUser user) async {
    if (!_skipServerRegistrationVerification()) return;
    _recoverStudentRegistrationIfNeeded(user);
    if (_cachedReg?.trim().isNotEmpty == true) return;
    final cached = await AuthSessionCache.load(user.uid);
    final reg = cached?.registrationNumber?.trim();
    if (reg != null && reg.isNotEmpty) {
      _cachedReg = StudentRegistrationNumber.normalize(reg);
    }
  }

  static const String signOutRequiresInternetMessage =
      'Sign out requires an internet connection. Turn on Wi‑Fi or mobile data, then try again.';

  static bool _looksLikeNetworkFailure(Object ex) {
    final blob = ex.toString().toLowerCase();
    if (ex is ApiAuthException) {
      final code = ex.code.toLowerCase();
      if (code == 'network-request-failed' || code == 'unavailable') {
        return true;
      }
    }
    if (ex is PlatformException) {
      final blob =
          '${ex.code} ${ex.message ?? ''} ${ex.details ?? ''}'.toLowerCase();
      if (blob.contains('network') || blob.contains('unavailable')) {
        return true;
      }
    }
    return blob.contains('unknownhostexception') ||
        blob.contains('unable to resolve host') ||
        blob.contains('no address associated with hostname') ||
        blob.contains('failed to resolve name') ||
        blob.contains('unreachable host') ||
        blob.contains('network error') ||
        blob.contains('network-request-failed') ||
        blob.contains('recaptchacallwrapper');
  }

  static String? _describeAuthChannelFailure(Object ex) {
    if (_looksLikeNetworkFailure(ex)) {
      if (kIsWeb && isInsecureApiBaseUrl) {
        return UserFacingErrors.secureWebInsecureApi;
      }
      return UserFacingErrors.apiConnectionBlocked;
    }
    final raw = ex.toString();
    if (ex is PlatformException) {
      final blob =
          '${ex.code} ${ex.message ?? ''} ${ex.details ?? ''}'.toLowerCase();
      if (blob.contains('network') || blob.contains('unavailable')) {
        return networkUnavailableMessage;
      }
    }
    if (raw.contains('pigeon')) {
      return UserFacingErrors.signInChannelFailure;
    }
    return null;
  }

  bool get hasApiSession =>
      _apiReady && ApiAuth.instance.currentUser != null;

  bool get isLoggedIn =>
      hasApiSession && !_forceSignedOut && !_signingOut;

  void _beginAuthenticating() {
    _authenticatingCount++;
  }

  void _endAuthenticating() {
    if (_authenticatingCount > 0) _authenticatingCount--;
  }

  /// True when signed in with @studmc.kiu.ac.ug and API has not confirmed the mailbox.
  bool get needsStudentEmailVerification {
    if (!_apiReady || _forceSignedOut) return false;
    return _needsStudentEmailVerification(ApiAuth.instance.currentUser);
  }

  /// True when signed in with @kiu.ac.ug staff email pending verification.
  bool get needsKiuStaffEmailVerification {
    if (!_apiReady || _forceSignedOut) return false;
    return _needsKiuStaffEmailVerification(ApiAuth.instance.currentUser);
  }

  bool get needsEmailVerification =>
      needsStudentEmailVerification || needsKiuStaffEmailVerification;

  /// After staff email is verified, ask whether the user is a KIU administrator.
  bool get needsKiuAdminOnboarding {
    if (!_apiReady || _forceSignedOut || !isLoggedIn) return false;
    if (needsEmailVerification) return false;
    final user = ApiAuth.instance.currentUser;
    if (user == null) return false;
    final email = user.email ?? '';
    if (!KiuStaffAuthEmail.isStaffMailbox(email)) return false;
    if (_isKiuAdmin || _kiuAdminOnboardingComplete) return false;
    // QA / full administrators (@kiu.ac.ug or ICT bypass) are not KIU administrators.
    if (_isAdmin) return false;
    return true;
  }

  String? _uiVisibleEmail(String? email) {
    final e = email?.trim();
    if (e == null || e.isEmpty) return null;
    return StaffAuthEmail.syntheticEmailToStaffNumber(e) != null ? null : e;
  }

  String? get currentUserEmail => _apiReady
      ? _uiVisibleEmail(ApiAuth.instance.currentUser?.email)
      : null;

  String? get currentRegistrationNumber => _cachedReg;
  String? get currentFullName => _cachedName;
  String? get currentKiuAdminJobTitle => _cachedKiuAdminJobTitle;
  String? get currentEmail => _uiVisibleEmail(_cachedEmail);

  void _applyWebBootSessionHint(bool? hint) {
    if (hint == true) {
      _pendingWebSessionRestore = true;
      _initialized = false;
      return;
    }
    _clearCaches();
    _initialized = true;
    _pendingWebSessionRestore = false;
  }

  Future<void> _finishWebInitialSession() async {
    final hint = WebFastBoot.cachedSessionHint;
    if (hint == false) {
      unawaited(_bindAuthStateWhenApiReady());
      return;
    }
    try {
      await AttendanceLocalQueues.ensureInitialized();
    } catch (_) {}

    const deadline = Duration(seconds: 8);
    final end = DateTime.now().add(deadline);
    while (!_apiReady && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    if (!_apiReady || !await _apiReachableForBoot()) {
      _showLoginWhenApiUnreachable();
      unawaited(_bindAuthStateWhenApiReady());
      return;
    }

    final hasCached = hint == true
        ? true
        : await AuthSessionCache.hasAnyCachedSession();
    if (hasCached && _apiReady) {
      try {
        final current = ApiAuth.instance.currentUser;
        if (current != null) {
          final cached = await AuthSessionCache.load(current.uid);
          if (cached != null) {
            _applySessionSnapshot(cached);
            _pendingWebSessionRestore = false;
            _initialized = true;
            notifyListeners();
          } else {
            _pendingWebSessionRestore = true;
            _initialized = false;
          }
        } else {
          _pendingWebSessionRestore = true;
          _initialized = false;
        }
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('AuthRepository._finishWebInitialSession: $e');
          debugPrint('$st');
        }
        _pendingWebSessionRestore = true;
        _initialized = false;
      }
    } else if (hasCached) {
      _pendingWebSessionRestore = true;
      _initialized = false;
    } else {
      _clearCaches();
      _initialized = true;
      _pendingWebSessionRestore = false;
    }
    notifyListeners();
    unawaited(_bindAuthStateWhenApiReady());
    unawaited(_authRestoreSafetyTimeout());
  }

  /// Never leave the login screen blocked behind "Signing you in…" forever.
  Future<void> _authRestoreSafetyTimeout() async {
    await Future<void>.delayed(const Duration(seconds: 6));
    if (isLoggedIn) return;
    if (!_pendingWebSessionRestore && _initialized) return;
    await abandonWebSessionRestore();
  }

  /// Clears a stuck web session restore and shows the login screen.
  Future<void> abandonWebSessionRestore() async {
    _pendingWebSessionRestore = false;
    _initialized = true;
    _forceSignedOut = false;
    try {
      await ApiClient.instance.clearToken();
    } catch (_) {}
    try {
      await ApiAuth.instance.signOut();
    } catch (_) {}
    _clearCaches();
    notifyListeners();
  }

  Future<bool> _apiReachableForBoot() async {
    try {
      await ApiClient.instance.ensureLoaded();
      return await ApiClient.instance.pingHealthQuick();
    } catch (_) {
      return false;
    }
  }

  void _showLoginWhenApiUnreachable() {
    _pendingWebSessionRestore = false;
    _initialized = true;
    _clearCaches();
    notifyListeners();
  }

  Future<void> loadInitialSession() async {
    await _authSub?.cancel();
    _authSub = null;

    if (WebFastBoot.enabled && !_apiReady) {
      _applyWebBootSessionHint(WebFastBoot.cachedSessionHint);
      notifyListeners();
      unawaited(_finishWebInitialSession());
      return;
    }

    if (!_apiReady) {
      // API still starting — check local session cache without forcing sign-out.
      notifyListeners();
      unawaited(_prepareBootBeforeApi());
      return;
    }

    await _bindAuthStateListener();
  }

  /// Opens local storage, then either shows login immediately (no cache) or waits
  /// for API auth to restore a persisted session.
  Future<void> _prepareBootBeforeApi() async {
    try {
      await AttendanceLocalQueues.ensureInitialized();
    } catch (_) {}

    final hasCached = await AuthSessionCache.hasAnyCachedSession();
    if (hasCached) {
      _pendingWebSessionRestore = true;
      _initialized = false;
    } else {
      _pendingWebSessionRestore = false;
      _initialized = true;
    }
    notifyListeners();
    unawaited(_bindAuthStateWhenApiReady());
    if (hasCached) {
      unawaited(_authRestoreSafetyTimeout());
      unawaited(_checkApiReachableWhileBooting());
    }
  }

  Future<void> _checkApiReachableWhileBooting() async {
    if (!await _apiReachableForBoot()) {
      _showLoginWhenApiUnreachable();
    }
  }

  Future<void> _bindAuthStateWhenApiReady() async {
    const deadline = Duration(seconds: 15);
    final end = DateTime.now().add(deadline);
    while (!_apiReady && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!_apiReady) {
      _pendingWebSessionRestore = false;
      _initialized = true;
      notifyListeners();
      return;
    }
    await _bindAuthStateListener();
  }

  Future<void> _bindAuthStateListener() async {
    _authSub = ApiAuth.instance.authStateChanges().listen(
      (user) async {
        var activeUser = user;
        final uid = activeUser?.uid;
        final forceRoleRefresh =
            uid != null && uid != _lastAuthStateUid;
        _lastAuthStateUid = uid;
        await _hydrateUser(
          activeUser,
          deferHeavyWork: true,
          forceRoleRefresh: forceRoleRefresh,
        );
        if (activeUser != null) {
          unawaited(_persistSessionCache(activeUser.uid));
          unawaited(_refreshStudentAuthIfNeeded(activeUser));
        }
        notifyListeners();
      },
      onError: (Object e, StackTrace st) {
        if (kDebugMode) {
          debugPrint('AuthRepository authStateChanges: $e');
          debugPrint('$st');
        }
      },
    );

    final current = ApiAuth.instance.currentUser;
    if (current != null) {
      _forceSignedOut = false;
      _pendingWebSessionRestore = false;
      final cached = await AuthSessionCache.load(current.uid);
      if (cached != null) {
        _applySessionSnapshot(cached);
      }
      _initialized = true;
      notifyListeners();
      unawaited(
        _hydrateUser(
          current,
          deferHeavyWork: true,
          forceRoleRefresh: true,
        ).then((_) => notifyListeners()),
      );
      return;
    }

    final hasCached = await AuthSessionCache.hasAnyCachedSession();
    if (hasCached) {
      _pendingWebSessionRestore = true;
      _initialized = false;
      notifyListeners();
      unawaited(_authRestoreSafetyTimeout());
      return;
    }

    _pendingWebSessionRestore = false;
    _initialized = true;
    notifyListeners();
  }

  /// Network refresh for student mailboxes — must not block first frame / shell paint.
  Future<void> _refreshStudentAuthIfNeeded(ApiUser user) async {
    if (!StudentAuthEmail.isStudentMailbox(user.email ?? '')) return;
    var studentUser = user;
    if (!studentUser.emailVerified && !WebFastBoot.enabled) {
      try {
        await studentUser.reload();
        await studentUser.getIdToken(true);
        studentUser = ApiAuth.instance.currentUser ?? studentUser;
      } catch (_) {}
    }
    if (studentUser.emailVerified) {
      await _linkStudentRegistrationAfterEmailVerified(studentUser);
    }
    await _hydrateUser(
      studentUser,
      deferHeavyWork: true,
      forceRoleRefresh: false,
    );
    notifyListeners();
  }

  void _applySessionSnapshot(AuthSessionSnapshot snapshot) {
    _cachedName = snapshot.fullName;
    _cachedKiuAdminJobTitle = snapshot.kiuAdminJobTitle;
    _kiuAdminOnboardingComplete = snapshot.kiuAdminOnboardingComplete;
    _isAdmin = snapshot.isAdmin;
    _isQaStaff = snapshot.isQaStaff;
    _isKiuAdmin = snapshot.isKiuAdmin;
    _adminCheckDone = true;
    _isLecturer = snapshot.isLecturer;
    _cachedStaffNumber = snapshot.staffNumber;
    _lecturerCheckDone = true;
    _apiRoleCheckDenied = false;
    _stripStaffRolesForStudentMailbox();
    if (isStudentAuthIdentity) {
      _cachedReg = snapshot.registrationNumber;
      _cachedIsStudentProfile = snapshot.isStudent ?? true;
      return;
    }
    final staffCached =
        _isAdmin || _isQaStaff || _isKiuAdmin || _isLecturer;
    _cachedReg = staffCached ? null : snapshot.registrationNumber;
    if (staffCached) {
      _cachedIsStudentProfile = false;
    } else if (snapshot.isStudent != null) {
      _cachedIsStudentProfile = snapshot.isStudent;
    } else if (snapshot.registrationNumber != null) {
      _cachedIsStudentProfile = null;
    } else {
      _cachedIsStudentProfile = false;
    }
    if (staffCached) {
      _ensureCachedStaffNumberFromAuthEmail(
        ApiAuth.instance.currentUser?.email ?? _cachedEmail,
      );
    }
  }

  /// Loads registration from [app_users] / [student_registrations] when cache is empty.
  Future<void> ensureStudentRegistrationHydrated({bool force = false}) async {
    final user = ApiAuth.instance.currentUser;
    if (user == null || !StudentAuthEmail.isStudentMailbox(user.email ?? '')) {
      return;
    }
    if (!force && _cachedReg?.trim().isNotEmpty == true) return;

    if (_registrationHydrateInFlight != null) {
      await _registrationHydrateInFlight;
      return;
    }

    if (!force &&
        _lastRegistrationHydrateAttemptAt != null &&
        DateTime.now().difference(_lastRegistrationHydrateAttemptAt!) <
            _registrationHydrateCooldown) {
      return;
    }

    _registrationHydrateInFlight = _doEnsureStudentRegistrationHydrated(user);
    try {
      await _registrationHydrateInFlight;
    } finally {
      _registrationHydrateInFlight = null;
    }
  }

  /// Retries deferred [student_registrations] linking after connectivity returns.
  Future<void> resumeStudentRegistrationLinkIfOnline() async {
    if (_skipServerRegistrationVerification()) return;
    final user = ApiAuth.instance.currentUser;
    if (user == null || !StudentAuthEmail.isStudentMailbox(user.email ?? '')) {
      return;
    }
    if (!user.emailVerified) return;
    final linkErr = await _linkStudentRegistrationAfterEmailVerified(user);
    if (linkErr != null) {
      _presentStudentRegistrationConflict(linkErr);
    } else {
      clearStudentRegistrationConflictMessage();
      unawaited(_persistSessionCache(user.uid));
      notifyListeners();
    }
  }

  Future<void> _doEnsureStudentRegistrationHydrated(ApiUser user) async {
    _lastRegistrationHydrateAttemptAt = DateTime.now();
    if (_cachedReg?.trim().isNotEmpty == true) return;

    if (_skipServerRegistrationVerification()) {
      await _applyCachedRegistrationWhenOffline(user);
      return;
    }

    if (await _ensureEmailVerifiedOnToken(user)) {
      final active = ApiAuth.instance.currentUser ?? user;
      await _linkStudentRegistrationAfterEmailVerified(active);
    }
    if (_cachedReg?.trim().isNotEmpty == true) {
      return;
    }

    await _recoverStudentRegistrationFromAttachedEmail(
      user,
      hydrateGeneration: _hydrateGeneration,
    );
    if (_cachedReg?.trim().isNotEmpty == true) {
    }
  }

  Future<void> _persistSessionCache(String uid) async {
    final id = uid.trim();
    if (id.isEmpty) return;
    try {
      await AuthSessionCache.save(
        AuthSessionSnapshot(
          uid: id,
          registrationNumber: _cachedReg,
          fullName: _cachedName,
          kiuAdminJobTitle: _cachedKiuAdminJobTitle,
          kiuAdminOnboardingComplete: _kiuAdminOnboardingComplete,
          isAdmin: _isAdmin,
          isQaStaff: _isQaStaff,
          isKiuAdmin: _isKiuAdmin,
          isLecturer: _isLecturer,
          staffNumber: _cachedStaffNumber,
          isStudent: isStudentAuthIdentity && isStudentProfile,
          cachedAt: DateTime.now().toUtc(),
        ),
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AuthRepository._persistSessionCache: $e');
        debugPrint('$st');
      }
    }
  }

  void _clearCaches() {
    _cachedReg = null;
    _registrationHydrateInFlight = null;
    _lastRegistrationHydrateAttemptAt = null;
    _cachedName = null;
    _cachedKiuAdminJobTitle = null;
    _cachedEmail = null;
    _isAdmin = false;
    _isQaStaff = false;
    _isKiuAdmin = false;
    _kiuAdminOnboardingComplete = false;
    _adminCheckDone = true;
    _isLecturer = false;
    _lecturerCheckDone = true;
    _cachedStaffNumber = null;
    _cachedIsStudentProfile = null;
    _apiRoleCheckDenied = false;
    _lastRoleHydrateUid = null;
    _verificationEmailQueuedAtSignup = false;
    unawaited(AuthSessionCache.clear());
  }

  Future<void> _rollbackIncompleteRegistration(
    ApiUser? user, {
    String? registrationNumber,
  }) async {
    if (user == null) return;
    if (registrationNumber != null && registrationNumber.trim().isNotEmpty) {
      await _deleteOwnPendingRegistrationLock(
        uid: user.uid,
        registrationNumber: registrationNumber,
      );
    }
    _forceSignedOut = true;
    notifyListeners();
    try {
      await user.delete();
    } catch (_) {}
    try {
      if (ApiAuth.instance.currentUser != null) {
        await ApiAuth.instance.signOut();
      }
    } catch (_) {}
    _clearCaches();
    _forceSignedOut = true;
  }

  /// API token may lag a beat after [createUserWithEmailAndPassword].
  Future<bool> _ensureApiAuthReady(ApiUser user, {int attempts = 4}) async {
    for (var i = 0; i < attempts; i++) {
      try {
        if (ApiAuth.instance.currentUser?.uid != user.uid) {
          await Future<void>.delayed(Duration(milliseconds: 150 * (i + 1)));
          continue;
        }
        await user.getIdToken(true);
        return true;
      } catch (_) {}
      await Future<void>.delayed(Duration(milliseconds: 200 * (i + 1)));
    }
    return ApiAuth.instance.currentUser?.uid == user.uid;
  }

  /// Reloads auth profile and refreshes token so the API sees email_verified.
  Future<bool> _ensureEmailVerifiedOnToken(ApiUser user, {int attempts = 4}) async {
    for (var i = 0; i < attempts; i++) {
      try {
        await user.reload();
      } catch (_) {}
      try {
        await user.getIdToken(true);
      } catch (_) {}
      final current = ApiAuth.instance.currentUser;
      if (current?.emailVerified == true) return true;
      await Future<void>.delayed(Duration(milliseconds: 250 * (i + 1)));
    }
    return ApiAuth.instance.currentUser?.emailVerified ?? user.emailVerified;
  }

  Future<void> _deleteOwnPendingRegistrationLock({
    required String uid,
    required String registrationNumber,
  }) async {
    final reg = StudentRegistrationNumber.normalize(registrationNumber);
    try {
      final ref = apiStore()
          .collection(ApiCollections.studentRegistrations)
          .doc(reg);
      final snap = await ref.get();
      if (!snap.exists) return;
      final d = snap.data();
      if (d == null) return;
      if ((d['uid'] as String?)?.trim() != uid) return;
      if (_studentRegistrationLockIsFinal(d)) return;
      await ref.delete();
    } catch (_) {}
  }

  /// Reserves [student_registrations/{reg}] as pending before email verification.
  Future<String?> _reserveStudentRegistrationPendingAtSignup({
    required String uid,
    required String email,
    required String registrationNumber,
    String? fullName,
  }) async {
    final reg = StudentRegistrationNumber.normalize(registrationNumber);
    final em = StudentAuthEmail.normalizeStudentEmail(email);
    final name = fullName?.trim();
    final db = apiStore();
    final regRef = db
        .collection(ApiCollections.studentRegistrations)
        .doc(reg);
    try {
      String? conflictCode;
      await db.runTransaction<void>((transaction) async {
        final existing = await transaction.get(regRef);
        if (existing.exists) {
          final d = existing.data();
          final lockFinal = _studentRegistrationLockIsFinal(d);
          final ownerUid = (d?['uid'] as String?)?.trim() ?? '';
          final ownerEmail =
              StudentAuthEmail.normalizeStudentEmail((d?['email'] as String?) ?? '');
          if (lockFinal) {
            if (ownerEmail.isNotEmpty && ownerEmail != em) {
              conflictCode = 'email_mismatch';
              return;
            }
            if (ownerUid.isNotEmpty && ownerUid != uid) {
              conflictCode = 'taken';
              return;
            }
            if (ownerUid == uid && ownerEmail == em) {
              return;
            }
          } else {
            if (ownerUid.isNotEmpty && ownerUid != uid) {
              conflictCode = 'taken';
              return;
            }
            if (ownerUid == uid && ownerEmail == em) {
              return;
            }
            if (ownerUid.isNotEmpty && ownerEmail.isNotEmpty && ownerEmail != em) {
              conflictCode = 'email_mismatch';
              return;
            }
          }
        }
        transaction.set(regRef, <String, dynamic>{
          'uid': uid,
          'email': em,
          'registrationNumber': reg,
          studentRegEmailVerifiedLinkField: false,
          'createdAt': ApiFieldValue.serverTimestamp(),
          if (name != null && name.isNotEmpty) 'fullName': name,
        });
      });
      if (conflictCode != null) {
        return _studentRegConflictMessage(_StudentRegConflict(conflictCode!), reg);
      }
      return null;
    } on ApiException catch (fe) {
      if (fe.code == 'permission-denied') {
        if (kDebugMode) {
          debugPrint(
            'AuthRepository._reserveStudentRegistrationPendingAtSignup permission-denied '
            '(db=django-api, reg=$reg, uid=$uid): ${fe.message}',
          );
        }
        return UserFacingErrors.registrationVerifyFailed;
      }
      return UserFacingErrors.registrationVerifyGeneric;
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          'AuthRepository._reserveStudentRegistrationPendingAtSignup: $e',
        );
      }
      return 'Could not verify your registration number. Please try again.';
    }
  }

  void _logRoleRulesDeployHintOnce() {
    if (!kDebugMode || _loggedRoleRulesDeployHint) return;
    _loggedRoleRulesDeployHint = true;
    debugPrint(
      'AuthRepository: role profile read denied — check Django API '
      'permissions for $uPanelApiBaseUrl.',
    );
  }

  static const Duration _passwordChangeTimeout = Duration(seconds: 20);

  Future<void> _hydrateUser(
    ApiUser? user, {
    bool deferHeavyWork = false,
    bool forceRoleRefresh = false,
    bool allowDuringAuth = false,
  }) async {
    if (_signingOut) {
      if (user == null) {
        _forceSignedOut = true;
        _clearCaches();
      }
      return;
    }

    if (_changingPassword) {
      return;
    }

    if (_authenticatingCount > 0 && !allowDuringAuth) {
      return;
    }

    if (user == null) {
      // authStateChanges can emit null while currentUser is still set — ignore.
      if (ApiAuth.instance.currentUser != null) return;
      // Native/web cold start: API may emit null before persisted auth loads.
      if (_pendingWebSessionRestore || !_initialized) return;
      _forceSignedOut = true;
      _clearCaches();
      return;
    }

    _pendingWebSessionRestore = false;
    _initialized = true;

    if (_forceSignedOut) {
      if (ApiAuth.instance.currentUser != null) {
        _forceSignedOut = false;
      } else {
        return;
      }
    }

    final uid = user.uid;
    if (_activeHydrate != null && _activeHydrateUid == uid) {
      await _activeHydrate;
      return;
    }

    final task = _hydrateUserBody(
      user,
      deferHeavyWork: deferHeavyWork,
      forceRoleRefresh: forceRoleRefresh,
    );
    _activeHydrate = task;
    _activeHydrateUid = uid;
    try {
      await task;
    } finally {
      if (_activeHydrate == task) {
        _activeHydrate = null;
        _activeHydrateUid = null;
      }
    }
  }

  Future<void> _hydrateUserBody(
    ApiUser user, {
    required bool deferHeavyWork,
    bool forceRoleRefresh = false,
  }) async {
    final gen = ++_hydrateGeneration;
    final uid = user.uid;
    final studentMailbox =
        StudentAuthEmail.isStudentMailbox(_authMailboxEmail(user));

    _forceSignedOut = false;
    _cachedEmail = _uiVisibleEmail(user.email);
    _ensureCachedStaffNumberFromAuthEmail(user.email ?? _cachedEmail);

    if (gen != _hydrateGeneration) return;

    final pendingVerification =
        _needsStudentEmailVerification(user) ||
        _needsKiuStaffEmailVerification(user);

    if (pendingVerification) {
      _adminCheckDone = true;
      _lecturerCheckDone = true;
      _isAdmin = false;
      _isQaStaff = false;
      _isKiuAdmin = false;
      _isLecturer = false;
      _apiRoleCheckDenied = false;
      try {
        final doc = await apiStore()
            .collection(ApiCollections.appUsers)
            .doc(uid)
            .get();
        if (gen != _hydrateGeneration) return;
        if (doc.exists && doc.data() != null) {
          final d = doc.data()!;
          final pending =
              (d[pendingRegistrationNumberField] as String?)?.trim();
          final n = (d['fullName'] as String?)?.trim();
          _cachedName = (n != null && n.isNotEmpty) ? n : null;
          _cachedReg = (pending != null && pending.isNotEmpty)
              ? StudentRegistrationNumber.normalize(pending)
              : null;
          _applyIsStudentFromProfileData(d, user);
          if (_cachedReg == null || _cachedReg!.isEmpty) {
            final hint = _studentRegistrationFromProfile(d);
            final fromLink = await _lookupStudentRegistrationFromEmailLink(
              user,
              registrationHint: hint,
            );
            if (gen != _hydrateGeneration) return;
            if (fromLink != null && fromLink.isNotEmpty) {
              _cachedReg = fromLink;
            }
          }
          clearStudentRegistrationConflictMessage();
        } else {
          _applyIsStudentFromProfileData(null, user);
        }
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('AuthRepository._hydrateUser pending verify: $e');
          debugPrint('$st');
        }
      }
      if (gen == _hydrateGeneration) {
        unawaited(_persistSessionCache(uid));
      }
      return;
    }

    final cachedSession = await AuthSessionCache.load(uid);
    if (cachedSession != null) {
      _applySessionSnapshot(cachedSession);
      _ensureCachedStaffNumberFromAuthEmail(user.email ?? _cachedEmail);
    }

    final skipRoleReads = !forceRoleRefresh &&
        _lastRoleHydrateUid == uid &&
        _adminCheckDone &&
        _lecturerCheckDone &&
        _identityHydrationComplete(user);
    final profileFuture = apiStore()
        .collection(ApiCollections.appUsers)
        .doc(uid)
        .get();
    final rolesFuture = skipRoleReads
        ? null
        : Future.wait([
            _refreshIsAdmin(uid),
            _refreshIsLecturer(uid),
          ]);

    ApiDocumentSnapshot? doc;
    Map<String, dynamic>? profileData;

    try {
      if (rolesFuture != null) {
        final results = await Future.wait<dynamic>([
          profileFuture,
          rolesFuture,
        ]);
        if (gen != _hydrateGeneration) return;
        doc = results[0] as ApiDocumentSnapshot;
        _lastRoleHydrateUid = uid;
      } else {
        doc = await profileFuture;
      }

      if (doc.exists && doc.data() != null) {
        profileData = doc.data()!;
        final d = profileData;
        final n = (d['fullName'] as String?)?.trim();
        _cachedName = (n != null && n.isNotEmpty) ? n : null;
        _cachedKiuAdminJobTitle = KiuAdminJobTitle.normalize(
          d[kiuAdminJobTitleField] as String?,
        );
        _kiuAdminOnboardingComplete =
            d[kiuAdminOnboardingCompleteField] == true;
        _applyIsStudentFromProfileData(d, user);
        if (_isStudentAccountProfile(d, user)) {
          _applyStudentRegistrationFromProfileData(d, user);
          clearStudentRegistrationConflictMessage();
        } else {
          // Staff: KIU ID lives on app_users / admins / lecturers — not student reg.
          _cachedReg = null;
          _applyStaffNumberFromData(d);
          clearStudentRegistrationConflictMessage();
        }
        _ensureCachedStaffNumberFromAuthEmail(user.email ?? _cachedEmail);
        if (gen == _hydrateGeneration) {
          unawaited(_backfillAppUserIsStudentFlag(uid));
        }
      } else {
        if (studentMailbox) {
          _applyIsStudentFromProfileData(null, user);
        } else {
          _cachedReg = null;
          _cachedName = null;
          _cachedKiuAdminJobTitle = null;
          _kiuAdminOnboardingComplete = false;
          _applyIsStudentFromProfileData(null, user);
        }
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AuthRepository._hydrateUser profile: $e');
        debugPrint('$st');
      }
      // Keep previously cached reg/name on transient network/read failures.
    }

    if (gen != _hydrateGeneration) return;
    if (studentMailbox) {
      await _recoverStudentRegistrationFromAttachedEmail(
        user,
        profileData: profileData,
        hydrateGeneration: gen,
      );
      if (gen == _hydrateGeneration && user.emailVerified) {
        Future<void> linkFuture() => _linkStudentRegistrationAfterEmailVerified(user)
            .then((linkErr) {
          if (linkErr != null) {
            if (_authFormErrorMessage != linkErr) {
              _presentStudentRegistrationConflict(linkErr);
            }
          } else {
            clearStudentRegistrationConflictMessage();
          }
          if (gen == _hydrateGeneration) {
            unawaited(_persistSessionCache(uid));
            notifyListeners();
          }
        });
        if (deferHeavyWork) {
          unawaited(linkFuture());
        } else {
          await linkFuture();
        }
      }
    } else if (deferHeavyWork) {
      unawaited(
        _recoverStudentRegistrationFromAttachedEmail(
          user,
          profileData: profileData,
          hydrateGeneration: gen,
        ),
      );
    } else {
      await _recoverStudentRegistrationFromAttachedEmail(
        user,
        profileData: profileData,
        hydrateGeneration: gen,
      );
    }
    _lastRoleHydrateUid = uid;
    if (deferHeavyWork) {
      unawaited(
        _maybeApplyPendingKiuStaffAccountRole(
          user,
          profileData: profileData,
        ),
      );
    } else {
      await _maybeApplyPendingKiuStaffAccountRole(
        user,
        profileData: profileData,
      );
    }

    if (gen == _hydrateGeneration) {
      unawaited(_persistSessionCache(uid));
      notifyListeners();
    }
  }

  Future<void> _maybeApplyPendingKiuStaffAccountRole(
    ApiUser user, {
    Map<String, dynamic>? profileData,
  }) async {
    if (_kiuAdminOnboardingComplete || _isKiuAdmin) return;
    if (_needsKiuStaffEmailVerification(user)) return;
    final email = user.email ?? '';
    if (!KiuStaffAuthEmail.isStaffMailbox(email)) return;

    try {
      final data = profileData ??
          (await apiStore()
                  .collection(ApiCollections.appUsers)
                  .doc(user.uid)
                  .get())
              .data();
      if (data == null) return;
      if (data[kiuAdminOnboardingCompleteField] == true) return;
      _applyStaffNumberFromData(data);
      final role = data[staffAccountRoleField] as String?;
      if (role == null || role.isEmpty) return;

      final isKiuAdministrator = role == staffAccountRoleKiuAdministrator;
      final reg = (_cachedReg?.trim().isNotEmpty == true)
          ? _cachedReg!.trim()
          : KiuAdminRegistrationNumber.example;
      final name = (_cachedName?.trim().isNotEmpty == true)
          ? _cachedName!.trim()
          : 'KIU Staff';
      await _applyKiuStaffAccountRole(
        uid: user.uid,
        email: KiuStaffAuthEmail.normalizeStaffEmail(email),
        fullName: name,
        registrationNumber: reg,
        isKiuAdministrator: isKiuAdministrator,
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AuthRepository._maybeApplyPendingKiuStaffAccountRole: $e');
        debugPrint('$st');
      }
    }
  }

  Future<void> _applyKiuStaffAccountRole({
    required String uid,
    required String email,
    required String fullName,
    required String registrationNumber,
    required bool isKiuAdministrator,
    String? grantedByUid,
    String? kiuAdminJobTitle,
  }) async {
    final normalizedTitle = isKiuAdministrator
        ? KiuAdminJobTitle.normalize(kiuAdminJobTitle)
        : null;
    final db = apiStore();
    final batch = db.batch();
    final appRef = db.collection(ApiCollections.appUsers).doc(uid);
    final lecturerRef = db.collection(ApiCollections.lecturers).doc(uid);

    if (isKiuAdministrator) {
      batch.set(
        db.collection(ApiCollections.admins).doc(uid),
        <String, dynamic>{
          adminIsKiuAdminField: true,
          adminIsAdminField: false,
          'email': email,
          'registrationNumber': registrationNumber,
          'fullName': fullName,
          if (normalizedTitle != null) kiuAdminJobTitleField: normalizedTitle,
          if (grantedByUid != null) 'grantedBy': grantedByUid,
          'createdAt': ApiFieldValue.serverTimestamp(),
        },
        ApiSetOptions(merge: true),
      );
    }

    batch.set(
      lecturerRef,
      <String, dynamic>{
        lecturerIsLecturerField: true,
        'registrationNumber': registrationNumber,
        'fullName': fullName,
        'email': email,
        if (grantedByUid != null) 'grantedBy': grantedByUid,
        'createdAt': ApiFieldValue.serverTimestamp(),
      },
      ApiSetOptions(merge: true),
    );

    batch.set(
      appRef,
      <String, dynamic>{
        kiuAdminOnboardingCompleteField: true,
        staffAccountRoleField: isKiuAdministrator
            ? staffAccountRoleKiuAdministrator
            : staffAccountRoleStaff,
        if (normalizedTitle != null) kiuAdminJobTitleField: normalizedTitle,
      },
      ApiSetOptions(merge: true),
    );

    await batch.commit();
    if (normalizedTitle != null) {
      _cachedKiuAdminJobTitle = normalizedTitle;
    }
    await _refreshIsAdmin(uid);
    await _refreshIsLecturer(uid);
    _kiuAdminOnboardingComplete = true;
    notifyListeners();
  }

  Future<void> _refreshIsAdmin(String uid) async {
    if (!_apiReady) {
      _isAdmin = false;
      _isQaStaff = false;
      _isKiuAdmin = false;
      _adminCheckDone = true;
      return;
    }
    try {
      final snap = await _fetchAdminRoleDoc(uid);
      final data = snap.data();
      _apiRoleCheckDenied = false;
      _isKiuAdmin = snap.exists && _kiuAdminFlagFromData(data);
      _isAdmin = snap.exists && _adminFlagFromData(data);
      _isQaStaff = snap.exists && _adminDocIsQaStaff(data);
      if (_isQaStaff && !_isAdmin) {
        _isAdmin = true;
      }
      if (_isKiuAdmin && data != null) {
        final title =
            KiuAdminJobTitle.normalize(data[kiuAdminJobTitleField] as String?);
        if (title != null) {
          _cachedKiuAdminJobTitle = title;
        }
      }
      if (_isAdmin && snap.exists && data != null) {
        _applyStaffNumberFromData(data);
        final canonical = data[adminIsAdminField];
        if (canonical != true) {
          unawaited(
            snap.reference.set(
              <String, dynamic>{adminIsAdminField: true},
              ApiSetOptions(merge: true),
            ),
          );
        }
        if (_isQaStaff && data[adminRoleField] == null) {
          unawaited(
            snap.reference.set(
              <String, dynamic>{adminRoleField: adminRoleQaStaff},
              ApiSetOptions(merge: true),
            ),
          );
        }
      }
    } catch (e, st) {
      if (_isApiPermissionDenied(e)) {
        _apiRoleCheckDenied = true;
        _logRoleRulesDeployHintOnce();
        // Keep cached staff flags when rules block re-read (avoid student UI flash).
      } else {
        if (kDebugMode) {
          debugPrint('AuthRepository._refreshIsAdmin: $e');
          debugPrint('$st');
        }
        _isAdmin = false;
        _isQaStaff = false;
        _isKiuAdmin = false;
      }
    }
    _stripStaffRolesForStudentMailbox();
    _adminCheckDone = true;
  }

  Future<void> _refreshIsLecturer(String uid) async {
    if (!_apiReady) {
      _isLecturer = false;
      _cachedStaffNumber = null;
      _lecturerCheckDone = true;
      return;
    }
    try {
      final snap = await apiStore()
          .collection(ApiCollections.lecturers)
          .doc(uid)
          .get();
      final data = snap.data();
      _isLecturer = snap.exists &&
          data != null &&
          data[lecturerIsLecturerField] == true;
      if (_isLecturer && data != null) {
        _applyStaffNumberFromData(data);
      }
      _ensureCachedStaffNumberFromAuthEmail(
        ApiAuth.instance.currentUser?.email ?? _cachedEmail,
      );
      if (_isLecturer && _hasCachedStaffIdentity()) {
        unawaited(
          StaffNumberDirectoryCache.remember(_cachedStaffNumber!, uid),
        );
      }
    } catch (e, st) {
      if (_isApiPermissionDenied(e)) {
        _apiRoleCheckDenied = true;
        _logRoleRulesDeployHintOnce();
        // Keep cached lecturer flag when rules block re-read.
      } else {
        if (kDebugMode) {
          debugPrint('AuthRepository._refreshIsLecturer: $e');
          debugPrint('$st');
        }
        _isLecturer = false;
        _cachedStaffNumber = null;
      }
    }
    _stripStaffRolesForStudentMailbox();
    _lecturerCheckDone = true;
  }

  static String _loginEmailForApi(String resolvedNormalized) {
    var e = normalizeEmail(resolvedNormalized);
    if (StudentAuthEmail.isStudentMailbox(e)) {
      e = StudentAuthEmail.normalizeStudentEmail(e);
    } else if (KiuStaffAuthEmail.isStaffMailbox(e)) {
      e = KiuStaffAuthEmail.normalizeStaffEmail(e);
    }
    return e;
  }

  /// Email, KIU4235S registration number, or KIU-#### staff id for [/api/auth/login/].
  static String? resolveLoginCredentialForApi(String rawLogin) {
    final trimmed = rawLogin.trim();
    if (trimmed.isEmpty) return null;

    final staffResolved = StaffAuthEmail.resolveLoginEmail(trimmed);
    if (staffResolved != null && staffResolved.contains('@')) {
      return _loginEmailForApi(staffResolved);
    }

    if (KiuAdminRegistrationNumber.looksLikeRegistrationNumberOnly(trimmed)) {
      return KiuAdminRegistrationNumber.normalize(trimmed);
    }

    final flexStaff = StaffAuthEmail.normalizeStaffNumberFlexible(trimmed);
    if (flexStaff != null) {
      return StaffAuthEmail.staffNumberToSyntheticEmail(flexStaff);
    }

    if (trimmed.contains('@')) {
      return _loginEmailForApi(trimmed);
    }

    return null;
  }

  /// Sign-in / password reset: student [@studmc|studwc.kiu.ac.ug], staff [@kiu.ac.ug], or KIU-####.
  static String? validateLoginEmailFormat(String raw) =>
      LoginEmail.validateForPasswordReset(raw);

  /// Email used for password reauthentication (password change).
  static String? passwordReauthEmail(ApiUser user) {
    final fallback = user.email;
    if (fallback == null || fallback.trim().isEmpty) return null;
    return _loginEmailForApi(fallback);
  }

  bool _needsStudentEmailVerification(ApiUser? user) {
    if (user == null) return false;
    final email = user.email ?? '';
    return StudentAuthEmail.isStudentMailbox(email) && !user.emailVerified;
  }

  bool _needsKiuStaffEmailVerification(ApiUser? user) {
    if (user == null) return false;
    final email = user.email ?? '';
    if (!KiuStaffAuthEmail.isStaffMailbox(email)) return false;
    if (KiuStaffAuthEmail.skipsVerification(email)) return false;
    return !user.emailVerified;
  }

  /// Sends verification link to the signed-in student mailbox.
  Future<String?> sendStudentEmailVerification() async {
    if (!_apiReady) return _apiNotReadyMessage();
    final user = ApiAuth.instance.currentUser;
    if (user == null) return 'You must be signed in.';
    if (!StudentAuthEmail.isStudentMailbox(user.email ?? '')) {
      return 'Email verification is only required for KIU student accounts.';
    }
    try {
      await user.sendEmailVerification();
      return null;
    } on ApiAuthException catch (ex) {
      if (ex.code == 'too-many-requests') {
        return 'Please wait a few minutes before requesting another email.';
      }
      return UserFacingErrors.sanitize(ex.message);
    } on PlatformException catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          UserFacingErrors.genericTryAgain;
    } catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          UserFacingErrors.genericTryAgain;
    }
  }

  /// Sends a password-reset link for KIU student or staff mailboxes.
  /// Returns null on success. Staff [KIU-####] logins are not supported (no real inbox).
  Future<String?> sendPasswordResetEmail({required String rawLogin}) async {
    if (!_apiReady) return _apiNotReadyMessage();
    if (AppConnectivity.instance.initialized &&
        !AppConnectivity.instance.isOnline) {
      return networkUnavailableMessage;
    }
    if (LoginEmail.isStaffNumberOnly(rawLogin)) {
      return 'Staff accounts (KIU-####) cannot reset a password by email. '
          'Ask your administrator, or sign in and change your password under Settings.';
    }
    final resolved = LoginEmail.resolve(rawLogin);
    if (resolved.isEmpty) {
      return 'Enter your KIU school email.';
    }
    if (!resolved.contains('@')) {
      return 'Enter your KIU school email '
          '(e.g. ${StudentAuthEmail.exampleEmail} or ${KiuStaffAuthEmail.exampleEmail}).';
    }
    if (LoginEmail.isSyntheticStaff(rawLogin)) {
      return 'Staff accounts (KIU-####) cannot reset a password by email. '
          'Ask your administrator, or sign in and change your password under Settings.';
    }
    final schoolErr = LoginEmail.validateForPasswordReset(rawLogin);
    if (schoolErr != null) return schoolErr;
    final em = LoginEmail.normalizeForPasswordReset(rawLogin);
    try {
      await ApiAuth.instance.sendPasswordResetEmail(email: em);
      return null;
    } on ApiAuthException catch (ex) {
      if (ex.code == 'user-not-found' || ex.code == 'invalid-email') {
        // Avoid revealing whether the account exists.
        return null;
      }
      if (ex.code == 'too-many-requests') {
        return 'Too many requests. Wait a few minutes, then try again.';
      }
      return UserFacingErrors.sanitize(ex.message);
    } on PlatformException catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          UserFacingErrors.genericTryAgain;
    } catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          UserFacingErrors.genericTryAgain;
    }
  }

  /// Reloads the Auth user and returns whether the student mailbox is verified.
  Future<bool> refreshStudentEmailVerified() async {
    if (!_apiReady) return false;
    final user = ApiAuth.instance.currentUser;
    if (user == null) return false;
    await user.reload();
    try {
      await user.getIdToken(true);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AuthRepository.refreshStudentEmailVerified token: $e');
      }
    }
    final verified = ApiAuth.instance.currentUser?.emailVerified ?? false;
    if (kDebugMode) {
      debugPrint(
        'AuthRepository emailVerified=$verified email=${user.email}',
      );
    }
    if (verified) {
      final current = ApiAuth.instance.currentUser;
      if (current != null) {
        await _linkStudentRegistrationAfterEmailVerified(current);
        await _hydrateUser(current, deferHeavyWork: true);
      }
    }
    notifyListeners();
    return verified;
  }

  /// Returns [AuthActionResult.ok] on success. Student accounts may require email verification first.
  Future<AuthActionResult> signInWithEmail({
    required String email,
    required String password,
  }) async {
    if (!_apiReady) {
      return _authActionError(_apiNotReadyMessage());
    }
    final loginCredential = resolveLoginCredentialForApi(email);
    if (loginCredential == null || loginCredential.isEmpty) {
      return _authActionError(
        'Enter your email, staff ID (${KiuAdminRegistrationNumber.example}), '
        'or KIU-####.',
      );
    }
    if (password.isEmpty) {
      return _authActionError('Enter your password.');
    }
    final isStaffLogin =
        StaffAuthEmail.syntheticEmailToStaffNumber(loginCredential) != null ||
            StaffAuthEmail.looksLikeStaffNumberOnly(email) ||
            KiuAdminRegistrationNumber.looksLikeRegistrationNumberOnly(email);
    if (loginCredential.contains('@') && !isStaffLogin) {
      final schoolErr = validateLoginEmailFormat(email);
      if (schoolErr != null) {
        return _authActionError(schoolErr);
      }
    }
    if (AppConnectivity.instance.initialized &&
        !AppConnectivity.instance.isOnline) {
      return _authActionError(networkUnavailableMessage);
    }
    _beginAuthenticating();
    notifyListeners();
    try {
      await ApiAuth.instance.signInWithEmailAndPassword(
        email: loginCredential,
        password: password,
      );
      _forceSignedOut = false;
      final signedIn = ApiAuth.instance.currentUser;
      if (signedIn != null) {
        final cached = await AuthSessionCache.load(signedIn.uid);
        if (cached != null) {
          _applySessionSnapshot(cached);
          _ensureCachedStaffNumberFromAuthEmail(signedIn.email);
          notifyListeners();
        }
        await _hydrateUser(
          signedIn,
          deferHeavyWork: true,
          allowDuringAuth: true,
        );
        if (StudentAuthEmail.isStudentMailbox(signedIn.email ?? '') &&
            signedIn.emailVerified) {
          await _linkStudentRegistrationAfterEmailVerified(signedIn);
        }
        await _persistSessionCache(signedIn.uid);
        notifyListeners();
      }
      final signedInUser = ApiAuth.instance.currentUser;
      clearAuthFormError();
      if (_needsStudentEmailVerification(signedInUser) ||
          _needsKiuStaffEmailVerification(signedInUser)) {
        return const AuthActionResult(needsEmailVerification: true);
      }
      return const AuthActionResult();
    } on ApiAuthException catch (ex) {
      return _authActionError(_mapAuthError(ex));
    } on PlatformException catch (ex) {
      return _authActionError(
        _describeAuthChannelFailure(ex) ?? UserFacingErrors.genericTryAgain,
      );
    } catch (ex) {
      return _authActionError(
        _describeAuthChannelFailure(ex) ?? UserFacingErrors.genericTryAgain,
      );
    } finally {
      _endAuthenticating();
      notifyListeners();
    }
  }

  String? _studentRegConflictMessage(_StudentRegConflict c, String reg) {
    switch (c.code) {
      case 'taken':
        return StudentRegistrationNumber.messageRegLinkedToAnotherAccount(reg);
      case 'email_mismatch':
        return StudentRegistrationNumber.messageRegLinkedToDifferentEmail(reg);
      default:
        return 'Registration number $reg cannot be used for this account.';
    }
  }

  /// Reserves [student_registrations/{reg}] for this uid + email (one reg per account).
  /// Only call after the student mailbox is verified in API auth.
  Future<String?> _checkStudentRegistrationAvailable({
    required String registrationNumber,
    required String email,
    required String uid,
  }) async {
    if (_skipServerRegistrationVerification()) return null;
    final reg = StudentRegistrationNumber.normalize(registrationNumber);
    final em = StudentAuthEmail.normalizeStudentEmail(email);
    try {
      final existing = await apiStore()
          .collection(ApiCollections.studentRegistrations)
          .doc(reg)
          .get();
      if (!existing.exists) return null;
      final d = existing.data();
      // Legacy / unverified locks must not block a different mailbox from signing up.
      if (!_studentRegistrationLockIsFinal(d)) return null;
      final ownerUid = (d?['uid'] as String?)?.trim() ?? '';
      final ownerEmail =
          StudentAuthEmail.normalizeStudentEmail((d?['email'] as String?) ?? '');
      if (ownerUid == uid) return null;
      if (ownerEmail.isNotEmpty && ownerEmail != em) {
        return _studentRegConflictMessage(
          _StudentRegConflict('email_mismatch'),
          reg,
        );
      }
      if (ownerUid.isNotEmpty && ownerUid != uid) {
        return _studentRegConflictMessage(_StudentRegConflict('taken'), reg);
      }
      return null;
    } on ApiException catch (fe) {
      if (fe.code == 'permission-denied') {
        return UserFacingErrors.registrationVerifyFailed;
      }
      return UserFacingErrors.registrationVerifyGeneric;
    } catch (e) {
      if (_looksLikeNetworkFailure(e)) return null;
      if (kDebugMode) {
        debugPrint(
          'AuthRepository._checkStudentRegistrationAvailable: $e',
        );
      }
      return 'Could not verify your registration number. Please try again.';
    }
  }

  String? _studentRegistrationFromProfile(Map<String, dynamic> data) {
    final linked = (data['registrationNumber'] as String?)?.trim();
    if (linked != null && linked.isNotEmpty) return linked;
    final pending =
        (data[pendingRegistrationNumberField] as String?)?.trim();
    if (pending != null && pending.isNotEmpty) return pending;
    return null;
  }

  Future<String?> _linkStudentRegistrationAfterEmailVerified(ApiUser user) async {
    if (!StudentAuthEmail.isStudentMailbox(user.email ?? '')) return null;
    if (!await _ensureEmailVerifiedOnToken(user)) return null;
    if (_skipServerRegistrationVerification()) return null;
    user = ApiAuth.instance.currentUser ?? user;

    final uid = user.uid;
    final doc = await apiStore()
        .collection(ApiCollections.appUsers)
        .doc(uid)
        .get();

    Map<String, dynamic>? data = doc.data();
    var reg = data != null ? _studentRegistrationFromProfile(data) : null;
    reg ??= await _lookupStudentRegistrationFromEmailLink(
      user,
      registrationHint: reg,
    );
    if (reg == null || reg.isEmpty) return null;

    final email = StudentAuthEmail.normalizeStudentEmail(user.email ?? '');
    final name = (data?['fullName'] as String?)?.trim();

    final linkErr = await _reserveStudentRegistration(
      uid: uid,
      email: email,
      registrationNumber: reg,
      fullName: name,
    );
    if (linkErr != null) {
      _presentStudentRegistrationConflict(linkErr);
      return linkErr;
    }
    clearStudentRegistrationConflictMessage();

    await apiStore().collection(ApiCollections.appUsers).doc(uid).set(
      <String, dynamic>{
        'registrationNumber': StudentRegistrationNumber.normalize(reg),
        pendingRegistrationNumberField: ApiFieldValue.delete(),
        appUserIsStudentField: true,
        'updatedAt': ApiFieldValue.serverTimestamp(),
      },
      ApiSetOptions(merge: true),
    );
    _cachedReg = StudentRegistrationNumber.normalize(reg);
    _cachedIsStudentProfile = true;
    return null;
  }

  Future<String?> _reserveStudentRegistration({
    required String uid,
    required String email,
    required String registrationNumber,
    String? fullName,
  }) async {
    if (_skipServerRegistrationVerification()) return null;
    final reg = StudentRegistrationNumber.normalize(registrationNumber);
    final em = StudentAuthEmail.normalizeStudentEmail(email);
    final name = fullName?.trim();
    final db = apiStore();
    final regRef = db
        .collection(ApiCollections.studentRegistrations)
        .doc(reg);

    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        final current = ApiAuth.instance.currentUser;
        if (current != null) {
          await _ensureEmailVerifiedOnToken(current, attempts: 2);
        }
        await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
      }
      try {
        // Do not throw inside the transaction callback — on web, JS interop wraps
        // Dart exceptions so `on _StudentRegConflict` never runs.
        String? conflictCode;
        await db.runTransaction<void>((transaction) async {
          final existing = await transaction.get(regRef);
          if (existing.exists) {
            final d = existing.data();
            final lockFinal = _studentRegistrationLockIsFinal(d);
            final ownerUid = (d?['uid'] as String?)?.trim() ?? '';
            final ownerEmail =
                StudentAuthEmail.normalizeStudentEmail((d?['email'] as String?) ?? '');
            if (lockFinal) {
              if (ownerEmail.isNotEmpty && ownerEmail != em) {
                conflictCode = 'email_mismatch';
                return;
              }
              if (ownerUid.isNotEmpty && ownerUid != uid) {
                conflictCode = 'taken';
                return;
              }
              final patch = <String, dynamic>{
                studentRegEmailVerifiedLinkField: true,
              };
              if (name != null && name.isNotEmpty) {
                patch['fullName'] = name;
              }
              transaction.set(regRef, patch, ApiSetOptions(merge: true));
              return;
            } else {
              // Replace an unverified / legacy lock with this verified account.
              transaction.set(regRef, <String, dynamic>{
                'uid': uid,
                'email': em,
                'registrationNumber': reg,
                studentRegEmailVerifiedLinkField: true,
                'createdAt': ApiFieldValue.serverTimestamp(),
                if (name != null && name.isNotEmpty) 'fullName': name,
              });
              return;
            }
          }
          transaction.set(regRef, <String, dynamic>{
            'uid': uid,
            'email': em,
            'registrationNumber': reg,
            studentRegEmailVerifiedLinkField: true,
            'createdAt': ApiFieldValue.serverTimestamp(),
            if (name != null && name.isNotEmpty) 'fullName': name,
          });
        });
        if (conflictCode != null) {
          return _studentRegConflictMessage(_StudentRegConflict(conflictCode!), reg);
        }
        return null;
      } on _StudentRegConflict catch (c) {
        return _studentRegConflictMessage(c, reg);
      } on ApiException catch (fe) {
        if (fe.code == 'permission-denied' && attempt < 2) {
          continue;
        }
        if (fe.code == 'permission-denied') {
          if (kDebugMode) {
            debugPrint(
              'AuthRepository._reserveStudentRegistration permission-denied '
              '(db=django-api, reg=$reg, uid=$uid): ${fe.message}',
            );
          }
          return UserFacingErrors.registrationLinkFailed;
        }
        return UserFacingErrors.registrationVerifyGeneric;
      } catch (e) {
        if (_looksLikeNetworkFailure(e)) return null;
        final conflict = _studentRegConflictFromError(e);
        if (conflict != null) {
          return _studentRegConflictMessage(conflict, reg);
        }
        if (kDebugMode) {
          debugPrint(
            'AuthRepository._reserveStudentRegistration: ${_formatApiFailure(e)}',
          );
        }
        return 'Could not verify your registration number. Please try again.';
      }
    }
    return UserFacingErrors.registrationLinkFailed;
  }

  /// Creates [app_users/{uid}] and sends a verification link to @studmc.kiu.ac.ug mailboxes.
  Future<AuthActionResult> registerWithEmail({
    required String email,
    required String fullName,
    required String password,
    required String registrationNumber,
  }) async {
    if (!_apiReady) {
      return _authActionError(_apiNotReadyMessage());
    }
    final formatErr = StudentAuthEmail.validateFormat(email);
    if (formatErr != null) {
      return _authActionError(formatErr);
    }
    final em = StudentAuthEmail.normalizeStudentEmail(email);
    final regErr = StudentRegistrationNumber.validateFormat(registrationNumber);
    if (regErr != null) {
      return _authActionError(regErr);
    }
    final reg = StudentRegistrationNumber.normalize(registrationNumber);
    final name = fullName.trim();
    if (name.isEmpty) {
      return _authActionError('Enter your full name.');
    }
    if (password.length < 6) {
      return _authActionError('Password must be at least 6 characters.');
    }
    if (AppConnectivity.instance.initialized &&
        !AppConnectivity.instance.isOnline) {
      return _authActionError(networkUnavailableMessage);
    }
    ApiUserCredential? cred;
    _beginAuthenticating();
    notifyListeners();
    try {
      await ApiClient.instance.ensureLoaded();
      cred = await ApiAuth.instance.createUserWithEmailAndPassword(
        email: em,
        password: password,
        fullName: name,
        registrationNumber: reg,
      );
      final user = cred.user;
      if (user == null) {
        return _authActionError(
          'Account created but user id is missing. Try signing in.',
        );
      }
      final uid = user.uid;
      if (uid.trim().isEmpty) {
        return _authActionError(
          'Account created but user id is missing. Try signing in.',
        );
      }

      if (!await _ensureApiAuthReady(user)) {
        return _authActionError(
          'Your account was created. Sign in with your email and password, '
          'then complete email verification.',
        );
      }

      // RegisterSerializer + sync_user_profile already create student_registrations
      // and accounts/users on the server — no extra document writes required here.
      _cachedIsStudentProfile = true;
      _cachedReg = reg;
      clearAuthFormError();

      try {
        await user.updateDisplayName(name);
      } catch (_) {}

      // Register API already queues the verification email.
      _forceSignedOut = false;
      markVerificationEmailQueuedAtSignup();
      clearAuthFormError();
      clearAuthFormDraft();
      try {
        await _hydrateUser(user, allowDuringAuth: true);
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('registerWithEmail: hydrate after signup: $e');
          debugPrint('$st');
        }
      }
      notifyListeners();
      return const AuthActionResult(needsEmailVerification: true);
    } on ApiAuthException catch (ex) {
      if (cred?.user == null &&
          (ex.code == 'network-request-failed' || ex.code == 'unavailable')) {
        final recovered = await _tryRecoverSignupAfterGatewayError(
          email: em,
          password: password,
          registrationNumber: reg,
          fullName: name,
        );
        if (recovered != null) return recovered;
      }
      return _authActionError(_mapAuthError(ex));
    } on PlatformException catch (ex) {
      return _authActionError(
        _describeAuthChannelFailure(ex) ?? UserFacingErrors.saveAccountFailed,
      );
    } on ApiException catch (fe) {
      if (cred?.user != null) {
        return _authActionError(
          'Your account was created. Sign in with your email and password.',
        );
      }
      if (fe.code == 'gateway-timeout' ||
          fe.code == 'unavailable' ||
          fe.code == 'http-502' ||
          fe.code == 'http-504') {
        final recovered = await _tryRecoverSignupAfterGatewayError(
          email: em,
          password: password,
          registrationNumber: reg,
          fullName: name,
        );
        if (recovered != null) return recovered;
        return _authActionError(
          'The server took too long while creating your account. '
          'Try signing in — your account may already exist.',
        );
      }
      if (fe.code.startsWith('http-4')) {
        return _authActionError(
          UserFacingErrors.sanitize(
            fe.message,
            fallback: UserFacingErrors.saveAccountFailed,
          ),
        );
      }
      return _authActionError(UserFacingErrors.saveAccountFailed);
    } catch (ex) {
      if (cred?.user != null) {
        return _authActionError(
          'Your account was created. Sign in with your email and password.',
        );
      }
      if (_looksLikeNetworkFailure(ex)) {
        final recovered = await _tryRecoverSignupAfterGatewayError(
          email: em,
          password: password,
          registrationNumber: reg,
          fullName: name,
        );
        if (recovered != null) return recovered;
        return _authActionError(
          'The server took too long while creating your account. '
          'Try signing in — your account may already exist.',
        );
      }
      return _authActionError(
        _describeAuthChannelFailure(ex) ?? UserFacingErrors.saveAccountFailed,
      );
    } finally {
      _endAuthenticating();
      notifyListeners();
    }
  }

  Future<void> _sendSignupVerificationEmail(ApiUser user) async {
    try {
      await user.sendEmailVerification();
    } on ApiAuthException catch (ex) {
      if (kDebugMode) {
        debugPrint(
          'AuthRepository._sendSignupVerificationEmail: ${ex.code} ${ex.message}',
        );
      }
    } catch (ex, st) {
      if (kDebugMode) {
        debugPrint('AuthRepository._sendSignupVerificationEmail: $ex');
        debugPrint('$st');
      }
    }
  }

  /// After a gateway timeout, the account may exist even though register returned an error.
  Future<AuthActionResult?> _tryRecoverSignupAfterGatewayError({
    required String email,
    required String password,
    required String registrationNumber,
    required String fullName,
  }) async {
    try {
      final cred = await ApiAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = cred.user;
      if (user == null) return null;
      _cachedIsStudentProfile = true;
      _cachedReg = StudentRegistrationNumber.normalize(registrationNumber);
      _forceSignedOut = false;
      clearAuthFormError();
      clearAuthFormDraft();
      markVerificationEmailQueuedAtSignup();
      try {
        await _hydrateUser(user, allowDuringAuth: true);
      } catch (_) {}
      notifyListeners();
      return const AuthActionResult(needsEmailVerification: true);
    } catch (_) {
      return null;
    }
  }

  String _mapAuthError(ApiAuthException ex) {
    switch (ex.code) {
      case 'invalid-email':
        return 'That email address is not valid.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Wrong email or password.';
      case 'email-already-in-use':
        return 'An account already exists for that email.';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters.';
      case 'too-many-requests':
        return ex.message.trim().isNotEmpty
            ? ex.message
            : 'Please wait a minute before requesting another verification email.';
      case 'network-request-failed':
      case 'unavailable':
        if (kIsWeb && isInsecureApiBaseUrl) {
          return UserFacingErrors.secureWebInsecureApi;
        }
        return UserFacingErrors.apiConnectionBlocked;
      default:
        return UserFacingErrors.sanitize(
          ex.message,
          fallback: UserFacingErrors.genericTryAgain,
        );
    }
  }

  Future<ApiAuth> _registrationAuth() async => ApiAuth.instance;

  /// Refreshes admin flag then returns an error message if the caller is not an admin.
  Future<String?> _requireAdmin({bool skipRefreshIfKnown = false}) async {
    if (!_apiReady) {
      return _apiNotReadyMessage();
    }
    final u = ApiAuth.instance.currentUser;
    if (u == null) return 'You must be signed in.';
    if (!skipRefreshIfKnown || !_adminCheckDone || !_isAdmin) {
      await _refreshIsAdmin(u.uid);
    }
    if (!_isAdmin) {
      if (_apiRoleCheckDenied) {
        return UserFacingErrors.adminProfileUnavailable;
      }
      return UserFacingErrors.notAdminForStaffCreation;
    }
    return null;
  }

  /// Like [_requireAdmin], but QA staff cannot promote others via [setAdminDocument].
  Future<String?> _requireFullAdministrator({bool skipRefreshIfKnown = false}) async {
    if (skipRefreshIfKnown && _adminCheckDone && isFullAdministrator) {
      return null;
    }
    final gate = await _requireAdmin(skipRefreshIfKnown: skipRefreshIfKnown);
    if (gate != null) return gate;
    if (!isFullAdministrator) {
      return 'Only full administrators can grant admin access by user id. '
          'Ask an administrator if someone needs access.';
    }
    return null;
  }

  /// Returns null on success, or a message when sign-out is blocked or fails.
  Future<String?> logout() async {
    if (_signingOut) return null;
    if (!AppConnectivity.instance.isOnline) {
      return signOutRequiresInternetMessage;
    }

    _signingOut = true;
    popToRootRoute();
    _sessionEpoch++;
    _forceSignedOut = true;
    clearAuthFormError();
    clearAuthFormDraft();
    final noticesDiskCacheUserKey = NoticesRepository.diskCacheUserKeyFrom(
      userId: currentUserId,
      registrationNumber: _cachedReg ?? currentRegistrationNumber,
    );
    _clearCaches();
    AppSessionReset.onSignOutImmediate();
    notifyListeners();

    try {
      if (_apiReady) {
        try {
          await ApiAuth.instance.signOut();
        } catch (e, st) {
          if (kDebugMode) {
            debugPrint('AuthRepository.logout signOut failed: $e');
            debugPrint('$st');
          }
          _forceSignedOut = false;
          if (_looksLikeNetworkFailure(e)) {
            return networkUnavailableMessage;
          }
          return 'Could not sign out. Check your connection and try again.';
        }
      }
      unawaited(
        AppSessionReset.onSignOutDeferred(
          noticesDiskCacheUserKey: noticesDiskCacheUserKey,
        ),
      );
      return null;
    } finally {
      _signingOut = false;
      notifyListeners();
    }
  }

  /// Changes password for the current signed-in user.
  ///
  /// Returns null on success; otherwise a user-friendly error message.
  Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (!_apiReady) {
      return _apiNotReadyMessage();
    }
    if (AppConnectivity.instance.initialized &&
        !AppConnectivity.instance.isOnline) {
      return networkUnavailableMessage;
    }
    final user = ApiAuth.instance.currentUser;
    if (user == null) return 'You must be signed in.';
    final reauthEmail = passwordReauthEmail(user);
    if (reauthEmail == null || reauthEmail.isEmpty) {
      return 'This account has no email/password sign-in method.';
    }
    if (currentPassword.isEmpty) return 'Enter your current password.';
    if (newPassword.isEmpty) return 'Enter a new password.';
    if (newPassword.length < 6) {
      return 'New password must be at least 6 characters.';
    }
    if (newPassword == currentPassword) {
      return 'New password must be different from your current password.';
    }

    _changingPassword = true;
    _hydrateGeneration++;
    notifyListeners();
    try {
      await user
          .changePassword(
            currentPassword: currentPassword,
            newPassword: newPassword,
          )
          .timeout(_passwordChangeTimeout);
      unawaited(
        user.reload().then((_) async {
          try {
            await user.getIdToken(true);
          } catch (_) {}
          _changingPassword = false;
          await _hydrateUser(ApiAuth.instance.currentUser);
          notifyListeners();
        }).catchError((Object _) {
          _changingPassword = false;
          notifyListeners();
        }),
      );
      return null;
    } on TimeoutException {
      return 'Password change timed out. Check your connection and try again.';
    } on ApiAuthException catch (ex) {
      return _mapChangePasswordError(ex);
    } on PlatformException catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          UserFacingErrors.genericTryAgain;
    } catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          UserFacingErrors.genericTryAgain;
    } finally {
      if (_changingPassword) {
        _changingPassword = false;
        notifyListeners();
      }
    }
  }

  String _mapChangePasswordError(ApiAuthException ex) {
    switch (ex.code) {
      case 'wrong-password':
      case 'invalid-credential':
        return 'Current password is incorrect.';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters.';
      case 'requires-recent-login':
        return 'For security, sign out and sign in again, then change your password.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a few minutes, then try again.';
      case 'network-request-failed':
      case 'unavailable':
        if (kIsWeb && isInsecureApiBaseUrl) {
          return UserFacingErrors.secureWebInsecureApi;
        }
        return UserFacingErrors.apiConnectionBlocked;
      case 'user-disabled':
        return 'This account has been disabled.';
      default:
        return UserFacingErrors.sanitize(
          ex.message,
          fallback: UserFacingErrors.genericTryAgain,
        );
    }
  }

  /// Writes [admins] / [targetUid] with [adminIsAdminField] = [isAdmin]. Caller must be an admin.
  Future<String?> setAdminDocument({
    required String targetUid,
    required bool isAdmin,
  }) async {
    final gate = await _requireFullAdministrator();
    if (gate != null) return gate;
    final uid = targetUid.trim();
    if (uid.isEmpty) return UserFacingErrors.invalidUserId;
    if (uid.contains('/') || uid.contains('..')) {
      return 'Invalid user id.';
    }
    try {
      await apiStore().collection(ApiCollections.admins).doc(uid).set(
        <String, dynamic>{
          adminIsAdminField: isAdmin,
          if (isAdmin) adminRoleField: adminRoleAdministrator,
          'grantedBy': ApiAuth.instance.currentUser!.uid,
          'updatedAt': ApiFieldValue.serverTimestamp(),
        },
        ApiSetOptions(merge: true),
      );
      if (uid == ApiAuth.instance.currentUser!.uid) {
        await _refreshIsAdmin(uid);
      }
      return null;
    } on ApiException catch (fe) {
      if (fe.code == 'permission-denied') {
        return UserFacingErrors.accessDenied;
      }
      return UserFacingErrors.sanitize(fe.message);
    } catch (ex) {
      return UserFacingErrors.genericTryAgain;
    }
  }

  /// Creates a new API user account,
  /// [app_users] profile, and [admins] with [isAdmin] true. Caller must be an admin.
  ///
  /// For new work, prefer [registerQaStaffAccount] (staff ID + default password, same as lecturers).
  Future<String?> registerNewAdminAccount({
    required String email,
    required String password,
    required String registrationNumber,
  }) async {
    final gate = await _requireAdmin();
    if (gate != null) return gate;
    final granter = ApiAuth.instance.currentUser;
    if (granter == null) return 'You must be signed in.';
    final granterUid = granter.uid;

    final em = normalizeEmail(email);
    if (em.isEmpty) return 'Enter an email.';
    if (!em.contains('@')) return 'Enter a valid email address.';
    final reg = registrationNumber.trim();
    if (reg.isEmpty) return 'Enter a registration number for the new admin.';
    if (password.length < 6) {
      return 'Password must be at least 6 characters.';
    }

    final regAuth = await _registrationAuth();
    ApiUserCredential? cred;
    try {
      cred = await regAuth.createUserWithEmailAndPassword(
        email: em,
        password: password,
      );
      final user = cred.user;
      if (user == null) {
        await regAuth.signOut();
        return 'Account created but user id is missing. Try signing in.';
      }
      final newUid = user.uid;
      await user.getIdToken(true);

      await apiStore().collection(ApiCollections.appUsers).doc(newUid).set({
        'email': em,
        'registrationNumber': _normalizeReg(reg),
        appUserIsStudentField: false,
        'createdAt': ApiFieldValue.serverTimestamp(),
      }, ApiSetOptions(merge: true));

      await apiStore().collection(ApiCollections.admins).doc(newUid).set(
        <String, dynamic>{
          adminIsAdminField: true,
          adminRoleField: adminRoleAdministrator,
          'grantedBy': granterUid,
          'createdAt': ApiFieldValue.serverTimestamp(),
          'email': em,
          'registrationNumber': _normalizeReg(reg),
        },
        ApiSetOptions(merge: true),
      );

      await regAuth.signOut();
      return null;
    } on ApiAuthException catch (ex) {
      try {
        await regAuth.signOut();
      } catch (_) {}
      return _mapAuthError(ex);
    } on PlatformException catch (ex) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      try {
        await regAuth.signOut();
      } catch (_) {}
      return _describeAuthChannelFailure(ex) ??
          UserFacingErrors.saveAccountFailed;
    } on ApiException catch (fe) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      try {
        await regAuth.signOut();
      } catch (_) {}
      if (fe.code == 'permission-denied') {
        return UserFacingErrors.saveAccountFailed;
      }
      return UserFacingErrors.saveAccountFailed;
    } catch (ex) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      try {
        await regAuth.signOut();
      } catch (_) {}
      return _describeAuthChannelFailure(ex) ??
          UserFacingErrors.saveAccountFailed;
    }
  }

  /// Allocates the next free `KIU-####` using [meta/lecturer_staff_counter] and
  /// skipping any [staff_numbers] docs that already exist (orphans / partial writes).
  ///
  /// Returns `(null, message)` on failure so callers can show [ApiException.code].
  Future<({String? staffNumber, String? errorMessage})>
      _allocateNextStaffNumberInTransaction() async {
    final db = apiStore();
    final metaRef = db
        .collection(ApiCollections.meta)
        .doc(ApiCollections.lecturerStaffCounterDocId);
    try {
      final allocated = await db.runTransaction<String>((transaction) async {
        final metaSnap = await transaction.get(metaRef);
        var next = 1;
        if (metaSnap.exists && metaSnap.data() != null) {
          final n = metaSnap.data()!['next'];
          if (n is int && n >= 1) {
            next = n;
          }
        }
        const maxScan = 80;
        for (var i = 0; i < maxScan; i++) {
          final staffNumber = 'KIU-${next.toString().padLeft(4, '0')}';
          final staffRef =
              db.collection(ApiCollections.staffNumbers).doc(staffNumber);
          final staffSnap = await transaction.get(staffRef);
          if (!staffSnap.exists) {
            transaction.set(
              metaRef,
              <String, dynamic>{
                'next': next + 1,
                'updatedAt': ApiFieldValue.serverTimestamp(),
              },
              ApiSetOptions(merge: true),
            );
            transaction.set(staffRef, <String, dynamic>{
              'pending': true,
              'createdAt': ApiFieldValue.serverTimestamp(),
            });
            return staffNumber;
          }
          next++;
        }
        throw StateError(
          'No free KIU-#### in $maxScan consecutive tries (staff_numbers). '
          'Remove orphan docs or raise meta counter.',
        );
      });
      return (staffNumber: allocated, errorMessage: null);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint(
          'AuthRepository._allocateNextStaffNumberInTransaction: ${_formatApiFailure(e)}',
        );
        debugPrint('$st');
      }
      final uid = ApiAuth.instance.currentUser?.uid;
      return (
        staffNumber: null,
        errorMessage: _formatStaffWriteFailure(
          stage: 'allocating staff number (meta/lecturer_staff_counter)',
          error: e,
          databaseId: 'django-api',
          currentUid: uid,
        ),
      );
    }
  }

  /// Creates lecturer API account (synthetic email), [app_users], [lecturers],
  /// and [staff_numbers] for manual ids. Caller must be admin.
  ///
  /// [manualStaffNumber]: when non-null/non-empty, must be `KIU-####` and unused.
  /// When null/empty, allocates next id from [meta/lecturer_staff_counter].
  Future<StaffRegistrationResult> registerLecturerAccount({
    required String fullName,
    String? manualStaffNumber,
  }) async {
    final name = fullName.trim();
    if (name.isEmpty) {
      return (error: 'Enter the staff member\'s name.', staffNumber: null);
    }
    final gate = await _requireAdmin(skipRefreshIfKnown: true);
    if (gate != null) return (error: gate, staffNumber: null);
    final granter = ApiAuth.instance.currentUser;
    if (granter == null) {
      return (error: 'You must be signed in.', staffNumber: null);
    }
    final granterUid = granter.uid;

    String? staffNumber;
    final manual = manualStaffNumber?.trim();
    if (manual != null && manual.isNotEmpty) {
      staffNumber = StaffAuthEmail.normalizeStaffNumber(manual);
      if (staffNumber == null) {
        return (
          error: 'Staff ID must look like KIU-0001 (KIU- plus four digits).',
          staffNumber: null,
        );
      }
    } else {
      final alloc = await _allocateNextStaffNumberInTransaction();
      staffNumber = alloc.staffNumber;
      if (staffNumber == null) {
        return (
          error: alloc.errorMessage ?? UserFacingErrors.staffNumberAllocateFailed,
          staffNumber: null,
        );
      }
    }

    final syntheticEmail = StaffAuthEmail.staffNumberToSyntheticEmail(staffNumber);
    if (syntheticEmail == null) {
      return (error: 'Invalid staff number for login email.', staffNumber: null);
    }
    const password = StaffAuthEmail.defaultLecturerPassword;
    if (password.length < 6) {
      return (error: 'Default lecturer password is invalid.', staffNumber: null);
    }

    final db = apiStore();
    final staffLockRef =
        db.collection(ApiCollections.staffNumbers).doc(staffNumber);

    if (manual != null && manual.isNotEmpty) {
      var idTaken = false;
      try {
        await db.runTransaction<void>((transaction) async {
          final snap = await transaction.get(staffLockRef);
          if (snap.exists) {
            idTaken = true;
            return;
          }
          transaction.set(staffLockRef, <String, dynamic>{
            'pending': true,
            'createdAt': ApiFieldValue.serverTimestamp(),
          });
        });
      } catch (e) {
        return (error: 'Could not reserve staff ID: $e', staffNumber: null);
      }
      if (idTaken) {
        return (error: 'That staff ID is already registered.', staffNumber: null);
      }
    }

    final regAuth = await _registrationAuth();
    ApiUserCredential? cred;
    try {
      cred = await regAuth.createUserWithEmailAndPassword(
        email: syntheticEmail,
        password: password,
      );
      final user = cred.user;
      if (user == null) {
        if (manual != null && manual.isNotEmpty) {
          await staffLockRef.delete();
        }
        await regAuth.signOut();
        return (
          error: 'Account created but user id is missing. Try again.',
          staffNumber: null,
        );
      }
      final newUid = user.uid;

      try {
        final batch = db.batch();
        batch.set(
          db.collection(ApiCollections.appUsers).doc(newUid),
          <String, dynamic>{
            'email': syntheticEmail,
            'registrationNumber': staffNumber,
            'staffNumber': staffNumber,
            'fullName': name,
            appUserIsStudentField: false,
            'createdAt': ApiFieldValue.serverTimestamp(),
          },
          ApiSetOptions(merge: true),
        );
        batch.set(
          db.collection(ApiCollections.lecturers).doc(newUid),
          <String, dynamic>{
            lecturerIsLecturerField: true,
            'staffNumber': staffNumber,
            'loginEmail': syntheticEmail,
            'fullName': name,
            'grantedBy': granterUid,
            'createdAt': ApiFieldValue.serverTimestamp(),
          },
          ApiSetOptions(merge: true),
        );
        batch.set(
          staffLockRef,
          <String, dynamic>{
            'uid': newUid,
            'staffNumber': staffNumber,
            'fullName': name,
            'assignedAt': ApiFieldValue.serverTimestamp(),
          },
          ApiSetOptions(merge: true),
        );
        await batch.commit();
      } catch (e) {
        throw StateError(_formatStaffWriteFailure(
          stage: 'writing lecturer profile (app_users, lecturers, staff_numbers)',
          error: e,
          databaseId: 'django-api',
          currentUid: granterUid,
        ));
      }

      unawaited(regAuth.signOut());
      return (error: null, staffNumber: staffNumber);
    } on ApiAuthException catch (ex) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      if (manual != null && manual.isNotEmpty) {
        try {
          await staffLockRef.delete();
        } catch (_) {}
      }
      try {
        await regAuth.signOut();
      } catch (_) {}
      return (error: _mapAuthError(ex), staffNumber: null);
    } on PlatformException catch (ex) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      if (manual != null && manual.isNotEmpty) {
        try {
          await staffLockRef.delete();
        } catch (_) {}
      }
      try {
        await regAuth.signOut();
      } catch (_) {}
      return (
        error: _describeAuthChannelFailure(ex) ??
            UserFacingErrors.saveAccountFailed,
        staffNumber: null,
      );
    } on ApiException catch (fe) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      if (manual != null && manual.isNotEmpty) {
        try {
          await staffLockRef.delete();
        } catch (_) {}
      }
      try {
        await regAuth.signOut();
      } catch (_) {}
      if (fe.code == 'permission-denied') {
        return (
          error: UserFacingErrors.saveAccountFailed,
          staffNumber: null,
        );
      }
      return (
        error: UserFacingErrors.saveAccountFailed,
        staffNumber: null,
      );
    } catch (ex) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      if (manual != null && manual.isNotEmpty) {
        try {
          await staffLockRef.delete();
        } catch (_) {}
      }
      try {
        await regAuth.signOut();
      } catch (_) {}
      return (
        error: _describeAuthChannelFailure(ex) ??
            UserFacingErrors.saveAccountFailed,
        staffNumber: null,
      );
    }
  }

  /// Creates QA staff API account (same synthetic `KIU-####` scheme as lecturers).
  Future<StaffRegistrationResult> registerQaStaffAccount({
    required String fullName,
    String? manualStaffNumber,
  }) async {
    return _registerStaffAdminAccount(
      fullName: fullName,
      manualStaffNumber: manualStaffNumber,
      adminRole: adminRoleQaStaff,
      roleLabel: 'QA staff',
      requireFullAdministrator: false,
    );
  }

  /// Creates a full administrator (KIU-#### sign-in, same flow as [registerQaStaffAccount]).
  Future<StaffRegistrationResult> registerAdministratorAccount({
    required String fullName,
    String? manualStaffNumber,
    bool markAsKiuAdministrator = false,
  }) async {
    return _registerStaffAdminAccount(
      fullName: fullName,
      manualStaffNumber: manualStaffNumber,
      adminRole: adminRoleAdministrator,
      roleLabel: 'administrator',
      requireFullAdministrator: true,
      markAsKiuAdministrator: markAsKiuAdministrator,
    );
  }

  Future<StaffRegistrationResult> _registerStaffAdminAccount({
    required String fullName,
    String? manualStaffNumber,
    required String adminRole,
    required String roleLabel,
    required bool requireFullAdministrator,
    bool markAsKiuAdministrator = false,
  }) async {
    final name = fullName.trim();
    if (name.isEmpty) {
      return (error: 'Enter the staff member\'s name.', staffNumber: null);
    }
    final gate = requireFullAdministrator
        ? await _requireFullAdministrator(skipRefreshIfKnown: true)
        : await _requireAdmin(skipRefreshIfKnown: true);
    if (gate != null) return (error: gate, staffNumber: null);
    final granter = ApiAuth.instance.currentUser;
    if (granter == null) {
      return (error: 'You must be signed in.', staffNumber: null);
    }
    final granterUid = granter.uid;

    String? staffNumber;
    final manual = manualStaffNumber?.trim();
    if (manual != null && manual.isNotEmpty) {
      staffNumber = StaffAuthEmail.normalizeStaffNumber(manual);
      if (staffNumber == null) {
        return (
          error: 'Staff ID must look like KIU-0001 (KIU- plus four digits).',
          staffNumber: null,
        );
      }
    } else {
      final alloc = await _allocateNextStaffNumberInTransaction();
      staffNumber = alloc.staffNumber;
      if (staffNumber == null) {
        return (
          error: alloc.errorMessage ?? UserFacingErrors.staffNumberAllocateFailed,
          staffNumber: null,
        );
      }
    }

    final syntheticEmail = StaffAuthEmail.staffNumberToSyntheticEmail(staffNumber);
    if (syntheticEmail == null) {
      return (error: 'Invalid staff number for login email.', staffNumber: null);
    }
    const password = StaffAuthEmail.defaultLecturerPassword;
    if (password.length < 6) {
      return (error: 'Default staff password is invalid.', staffNumber: null);
    }

    final db = apiStore();
    final staffLockRef =
        db.collection(ApiCollections.staffNumbers).doc(staffNumber);

    if (manual != null && manual.isNotEmpty) {
      var idTaken = false;
      try {
        await db.runTransaction<void>((transaction) async {
          final snap = await transaction.get(staffLockRef);
          if (snap.exists) {
            idTaken = true;
            return;
          }
          transaction.set(staffLockRef, <String, dynamic>{
            'pending': true,
            'createdAt': ApiFieldValue.serverTimestamp(),
          });
        });
      } catch (e) {
        return (error: 'Could not reserve staff ID: $e', staffNumber: null);
      }
      if (idTaken) {
        return (error: 'That staff ID is already registered.', staffNumber: null);
      }
    }

    final regAuth = await _registrationAuth();
    ApiUserCredential? cred;
    try {
      cred = await regAuth.createUserWithEmailAndPassword(
        email: syntheticEmail,
        password: password,
      );
      final user = cred.user;
      if (user == null) {
        if (manual != null && manual.isNotEmpty) {
          await staffLockRef.delete();
        }
        await regAuth.signOut();
        return (
          error: 'Account created but user id is missing. Try again.',
          staffNumber: null,
        );
      }
      final newUid = user.uid;

      try {
        final batch = db.batch();
        batch.set(
          db.collection(ApiCollections.appUsers).doc(newUid),
          <String, dynamic>{
            'email': syntheticEmail,
            'registrationNumber': _normalizeReg(staffNumber),
            'staffNumber': staffNumber,
            'fullName': name,
            appUserIsStudentField: false,
            'createdAt': ApiFieldValue.serverTimestamp(),
          },
          ApiSetOptions(merge: true),
        );
        batch.set(
          db.collection(ApiCollections.admins).doc(newUid),
          <String, dynamic>{
            adminIsAdminField: true,
            if (markAsKiuAdministrator) adminIsKiuAdminField: true,
            adminRoleField: adminRole,
            'grantedBy': granterUid,
            'createdAt': ApiFieldValue.serverTimestamp(),
            'email': syntheticEmail,
            'registrationNumber': _normalizeReg(staffNumber),
            'staffNumber': staffNumber,
            'fullName': name,
          },
          ApiSetOptions(merge: true),
        );
        if (markAsKiuAdministrator) {
          batch.set(
            db.collection(ApiCollections.lecturers).doc(newUid),
            <String, dynamic>{
              lecturerIsLecturerField: true,
              'registrationNumber': _normalizeReg(staffNumber),
              'staffNumber': staffNumber,
              'fullName': name,
              'email': syntheticEmail,
              'grantedBy': granterUid,
              'createdAt': ApiFieldValue.serverTimestamp(),
            },
            ApiSetOptions(merge: true),
          );
          batch.set(
            db.collection(ApiCollections.appUsers).doc(newUid),
            <String, dynamic>{
              kiuAdminOnboardingCompleteField: true,
            },
            ApiSetOptions(merge: true),
          );
        }
        batch.set(
          staffLockRef,
          <String, dynamic>{
            'uid': newUid,
            'staffNumber': staffNumber,
            'fullName': name,
            'assignedAt': ApiFieldValue.serverTimestamp(),
          },
          ApiSetOptions(merge: true),
        );
        await batch.commit();
      } catch (e) {
        throw StateError(_formatStaffWriteFailure(
          stage: 'writing $roleLabel profile (app_users, admins, staff_numbers)',
          error: e,
          databaseId: 'django-api',
          currentUid: granterUid,
        ));
      }

      unawaited(regAuth.signOut());
      return (error: null, staffNumber: staffNumber);
    } on ApiAuthException catch (ex) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      if (manual != null && manual.isNotEmpty) {
        try {
          await staffLockRef.delete();
        } catch (_) {}
      }
      try {
        await regAuth.signOut();
      } catch (_) {}
      return (error: _mapAuthError(ex), staffNumber: null);
    } on PlatformException catch (ex) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      if (manual != null && manual.isNotEmpty) {
        try {
          await staffLockRef.delete();
        } catch (_) {}
      }
      try {
        await regAuth.signOut();
      } catch (_) {}
      return (
        error: _describeAuthChannelFailure(ex) ??
            UserFacingErrors.saveAccountFailed,
        staffNumber: null,
      );
    } on ApiException catch (fe) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      if (manual != null && manual.isNotEmpty) {
        try {
          await staffLockRef.delete();
        } catch (_) {}
      }
      try {
        await regAuth.signOut();
      } catch (_) {}
      if (fe.code == 'permission-denied') {
        return (
          error:
              UserFacingErrors.saveAccountFailed,
          staffNumber: null,
        );
      }
      return (
        error: UserFacingErrors.saveAccountFailed,
        staffNumber: null,
      );
    } catch (ex) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      if (manual != null && manual.isNotEmpty) {
        try {
          await staffLockRef.delete();
        } catch (_) {}
      }
      try {
        await regAuth.signOut();
      } catch (_) {}
      return (
        error: _describeAuthChannelFailure(ex) ??
            UserFacingErrors.saveAccountFailed,
        staffNumber: null,
      );
    }
  }

  /// Self-registration for KIU staff ([@kiu.ac.ug] + KIU4235S registration number).
  Future<AuthActionResult> registerKiuStaffWithEmail({
    required String email,
    required String fullName,
    required String password,
    required String registrationNumber,
    required bool isKiuAdministrator,
    String? kiuAdminJobTitle,
  }) async {
    if (!_apiReady) {
      return AuthActionResult(error: _apiNotReadyMessage());
    }
    final formatErr = KiuStaffAuthEmail.validateFormat(email);
    if (formatErr != null) {
      return AuthActionResult(error: formatErr);
    }
    final em = KiuStaffAuthEmail.normalizeStaffEmail(email);
    final regErr = KiuAdminRegistrationNumber.validateFormat(registrationNumber);
    if (regErr != null) {
      return AuthActionResult(error: regErr);
    }
    final reg = KiuAdminRegistrationNumber.normalize(registrationNumber);
    final name = fullName.trim();
    final normalizedTitle = isKiuAdministrator
        ? KiuAdminJobTitle.normalize(kiuAdminJobTitle)
        : null;
    if (name.isEmpty) {
      return const AuthActionResult(error: 'Enter your full name.');
    }
    if (password.length < 6) {
      return const AuthActionResult(
        error: 'Password must be at least 6 characters.',
      );
    }
    if (AppConnectivity.instance.initialized &&
        !AppConnectivity.instance.isOnline) {
      return AuthActionResult(error: networkUnavailableMessage);
    }

    ApiUserCredential? cred;
    _beginAuthenticating();
    notifyListeners();
    try {
      cred = await ApiAuth.instance.createUserWithEmailAndPassword(
        email: em,
        password: password,
        fullName: name,
        registrationNumber: reg,
      );
      final user = cred.user;
      if (user == null) {
        return const AuthActionResult(
          error: 'Account created but user id is missing. Try signing in.',
        );
      }
      final uid = user.uid;
      try {
        await user.getIdToken(true);
      } catch (_) {}

      await apiStore().collection(ApiCollections.appUsers).doc(uid).set(
        <String, dynamic>{
          'email': em,
          'registrationNumber': reg,
          'fullName': name,
          appUserIsStudentField: false,
          staffAccountRoleField: isKiuAdministrator
              ? staffAccountRoleKiuAdministrator
              : staffAccountRoleStaff,
          if (normalizedTitle != null) kiuAdminJobTitleField: normalizedTitle,
          'createdAt': ApiFieldValue.serverTimestamp(),
        },
        ApiSetOptions(merge: true),
      );

      final skipVerify = KiuStaffAuthEmail.skipsVerification(em);
      // Register API already queues the verification email — do not request again here
      // (a second request hits the 60s cooldown and used to fail signup).

      if (skipVerify || user.emailVerified) {
        await _applyKiuStaffAccountRole(
          uid: uid,
          email: em,
          fullName: name,
          registrationNumber: reg,
          isKiuAdministrator: isKiuAdministrator,
          kiuAdminJobTitle: normalizedTitle,
        );
      }

      _forceSignedOut = false;
      markVerificationEmailQueuedAtSignup();
      clearAuthFormError();
      try {
        await _hydrateUser(user, allowDuringAuth: true);
      } catch (_) {}
      notifyListeners();

      final needsVerify = !skipVerify &&
          (_needsKiuStaffEmailVerification(user) || !user.emailVerified);
      return AuthActionResult(needsEmailVerification: needsVerify);
    } on ApiAuthException catch (ex) {
      if (ex.code == 'email-already-in-use') {
        final signInResult = await signInWithEmail(
          email: em,
          password: password,
        );
        if (signInResult.ok) {
          markVerificationEmailQueuedAtSignup();
          return signInResult;
        }
        return AuthActionResult(
          error: 'An account already exists for that email. '
              'Sign in with your password instead.',
        );
      }
      return AuthActionResult(error: _mapAuthError(ex));
    } catch (ex) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      return AuthActionResult(
        error: _describeAuthChannelFailure(ex) ?? 'Registration failed: $ex',
      );
    } finally {
      _endAuthenticating();
      notifyListeners();
    }
  }

  /// Full administrator creates a @kiu.ac.ug staff account (KIU administrator or lecturer staff).
  Future<({String? error, String? registrationNumber})>
      registerKiuAdministratorWithRealEmail({
    required String fullName,
    required String email,
    required String registrationNumber,
    required String password,
    required bool isKiuAdministrator,
    String? kiuAdminJobTitle,
  }) async {
    final gate = await _requireFullAdministrator(skipRefreshIfKnown: true);
    if (gate != null) return (error: gate, registrationNumber: null);

    final name = fullName.trim();
    if (name.isEmpty) {
      return (error: 'Enter the administrator\'s name.', registrationNumber: null);
    }

    final emRaw = email.trim().toLowerCase();
    final regErr = KiuAdminRegistrationNumber.validateFormat(registrationNumber);
    if (regErr != null) return (error: regErr, registrationNumber: null);
    final reg = KiuAdminRegistrationNumber.normalize(registrationNumber);
    final normalizedTitle = isKiuAdministrator
        ? KiuAdminJobTitle.normalize(kiuAdminJobTitle)
        : null;

    if (!emRaw.contains('@')) {
      return (error: 'Enter a valid email address.', registrationNumber: null);
    }
    final isKiuStaff = KiuStaffAuthEmail.isStaffMailbox(emRaw);
    final isBypass = KiuStaffAuthEmail.skipsVerification(emRaw);
    if (!isKiuStaff && !isBypass) {
      return (
        error: 'Use an official @${KiuStaffAuthEmail.staffEmailDomain} email '
            'or an ICT-approved exception address.',
        registrationNumber: null,
      );
    }
    if (password.length < 6) {
      return (
        error: 'Password must be at least 6 characters.',
        registrationNumber: null,
      );
    }

    final granter = ApiAuth.instance.currentUser;
    if (granter == null) {
      return (error: 'You must be signed in.', registrationNumber: null);
    }
    final granterUid = granter.uid;
    final db = apiStore();
    final regAuth = await _registrationAuth();
    ApiUserCredential? cred;

    try {
      cred = await regAuth.createUserWithEmailAndPassword(
        email: emRaw,
        password: password,
        fullName: name,
        registrationNumber: reg,
      );
      final user = cred.user;
      if (user == null) {
        await regAuth.signOut();
        return (
          error: 'Account created but user id is missing.',
          registrationNumber: null,
        );
      }
      final newUid = user.uid;

      final batch = db.batch();
      batch.set(
        db.collection(ApiCollections.appUsers).doc(newUid),
        <String, dynamic>{
          'email': emRaw,
          'registrationNumber': reg,
          'fullName': name,
          kiuAdminOnboardingCompleteField: true,
          staffAccountRoleField: isKiuAdministrator
              ? staffAccountRoleKiuAdministrator
              : staffAccountRoleStaff,
          if (normalizedTitle != null) kiuAdminJobTitleField: normalizedTitle,
          'createdAt': ApiFieldValue.serverTimestamp(),
        },
        ApiSetOptions(merge: true),
      );
      if (isKiuAdministrator) {
        batch.set(
          db.collection(ApiCollections.admins).doc(newUid),
          <String, dynamic>{
            adminIsKiuAdminField: true,
            adminIsAdminField: false,
            'grantedBy': granterUid,
            'createdAt': ApiFieldValue.serverTimestamp(),
            'email': emRaw,
            'registrationNumber': reg,
            'fullName': name,
            if (normalizedTitle != null) kiuAdminJobTitleField: normalizedTitle,
          },
          ApiSetOptions(merge: true),
        );
      }
      batch.set(
        db.collection(ApiCollections.lecturers).doc(newUid),
        <String, dynamic>{
          lecturerIsLecturerField: true,
          'registrationNumber': reg,
          'fullName': name,
          'email': emRaw,
          'grantedBy': granterUid,
          'createdAt': ApiFieldValue.serverTimestamp(),
        },
        ApiSetOptions(merge: true),
      );
      await batch.commit();
      await regAuth.signOut();
      return (error: null, registrationNumber: reg);
    } on ApiAuthException catch (ex) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      try {
        await regAuth.signOut();
      } catch (_) {}
      return (error: _mapAuthError(ex), registrationNumber: null);
    } on ApiException catch (fe) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      try {
        await regAuth.signOut();
      } catch (_) {}
      if (fe.code == 'permission-denied') {
        return (
          error: UserFacingErrors.saveAccountFailed,
          registrationNumber: null,
        );
      }
      return (error: UserFacingErrors.saveAccountFailed, registrationNumber: null);
    } catch (ex) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      try {
        await regAuth.signOut();
      } catch (_) {}
      return (error: UserFacingErrors.saveAccountFailed, registrationNumber: null);
    }
  }

  /// After @kiu.ac.ug email verification — grant KIU administrator or staff role.
  Future<String?> completeKiuAdminOnboarding({
    required bool isKiuAdministrator,
    String? kiuAdminJobTitle,
  }) async {
    if (!_apiReady) return _apiNotReadyMessage();
    final user = ApiAuth.instance.currentUser;
    if (user == null) return 'You must be signed in.';
    final uid = user.uid;
    final email = KiuStaffAuthEmail.normalizeStaffEmail(user.email ?? '');
    final reg = _cachedReg ?? KiuAdminRegistrationNumber.example;
    final name = _cachedName ?? 'KIU Staff';
    final normalizedTitle = isKiuAdministrator
        ? KiuAdminJobTitle.normalize(kiuAdminJobTitle)
        : null;

    try {
      await _applyKiuStaffAccountRole(
        uid: uid,
        email: email,
        fullName: name,
        registrationNumber: reg,
        isKiuAdministrator: isKiuAdministrator,
        kiuAdminJobTitle: normalizedTitle,
      );
      return null;
    } on ApiException catch (fe) {
      if (fe.code == 'permission-denied') {
        return UserFacingErrors.accessDenied;
      }
      return UserFacingErrors.sanitize(fe.message);
    } catch (e) {
      return UserFacingErrors.genericTryAgain;
    }
  }

  /// Which fields the signed-in user may edit on their own profile.
  SelfServiceProfileKind? get selfServiceProfileKind {
    if (!isLoggedIn) return null;
    if (_isLecturer && !_isAdmin && !_isKiuAdmin) {
      return SelfServiceProfileKind.lecturer;
    }
    final email = ApiAuth.instance.currentUser?.email ?? '';
    if (StudentAuthEmail.isStudentMailbox(email)) {
      return SelfServiceProfileKind.student;
    }
    return SelfServiceProfileKind.administrator;
  }

  String? get profileRegistrationExample {
    switch (selfServiceProfileKind) {
      case SelfServiceProfileKind.student:
        return StudentRegistrationNumber.example;
      case SelfServiceProfileKind.administrator:
        return KiuAdminRegistrationNumber.example;
      case SelfServiceProfileKind.lecturer:
        return LecturerRegistrationNumber.exampleHint;
      case null:
        return null;
    }
  }

  /// Updates [app_users/{uid}] full name and registration number for the current user.
  ///
  /// Returns null on success; otherwise a user-facing error message.
  Future<String?> updateProfileForCurrentUser({
    required String fullName,
    String? registrationNumber,
    String? kiuAdminJobTitle,
  }) async {
    if (!_apiReady) {
      return _apiNotReadyMessage();
    }
    if (AppConnectivity.instance.initialized &&
        !AppConnectivity.instance.isOnline) {
      return networkUnavailableMessage;
    }
    final user = ApiAuth.instance.currentUser;
    if (user == null) return 'You must be signed in.';

    final kind = selfServiceProfileKind;
    if (kind == null) return 'You must be signed in.';

    final uid = user.uid;
    final name = fullName.trim();
    if (name.isEmpty) return 'Enter your full name.';

    String? reg;
    switch (kind) {
      case SelfServiceProfileKind.lecturer:
        if (registrationNumber == null || registrationNumber.trim().isEmpty) {
          return 'Enter your registration number.';
        }
        final lecturerRegErr =
            LecturerRegistrationNumber.validateFormat(registrationNumber);
        if (lecturerRegErr != null) return lecturerRegErr;
        reg = LecturerRegistrationNumber.normalize(registrationNumber);
        break;
      case SelfServiceProfileKind.student:
        if (registrationNumber == null || registrationNumber.trim().isEmpty) {
          return 'Enter your registration number.';
        }
        final studentRegErr =
            StudentRegistrationNumber.validateFormat(registrationNumber);
        if (studentRegErr != null) return studentRegErr;
        reg = StudentRegistrationNumber.normalize(registrationNumber);
        final email = StudentAuthEmail.normalizeStudentEmail(user.email ?? '');
        if (!user.emailVerified) {
          if (reg != (_cachedReg ?? '')) {
            final availErr = await _checkStudentRegistrationAvailable(
              registrationNumber: reg,
              email: email,
              uid: uid,
            );
            if (availErr != null) return availErr;
          }
        } else if (reg != (_cachedReg ?? '')) {
          final linkErr = await _reserveStudentRegistration(
            uid: uid,
            email: email,
            registrationNumber: reg,
            fullName: name,
          );
          if (linkErr != null) {
            return linkErr;
          }
        }
        break;
      case SelfServiceProfileKind.administrator:
        if (registrationNumber == null || registrationNumber.trim().isEmpty) {
          return 'Enter your registration number.';
        }
        final adminRegErr =
            KiuAdminRegistrationNumber.validateFormat(registrationNumber);
        if (adminRegErr != null) return adminRegErr;
        reg = KiuAdminRegistrationNumber.normalize(registrationNumber);
        break;
    }

    final normalizedTitle = isKiuAdmin
        ? KiuAdminJobTitle.normalize(kiuAdminJobTitle)
        : null;
    final clearTitle = isKiuAdmin &&
        (kiuAdminJobTitle != null && kiuAdminJobTitle.trim().isEmpty);

    try {
      final data = <String, dynamic>{
        'fullName': name,
        'updatedAt': ApiFieldValue.serverTimestamp(),
      };
      if (kind == SelfServiceProfileKind.student) {
        data[appUserIsStudentField] = true;
        _cachedIsStudentProfile = true;
      }
      if (reg != null) {
        if (kind == SelfServiceProfileKind.student && !user.emailVerified) {
          data[pendingRegistrationNumberField] = reg;
          data['registrationNumber'] = ApiFieldValue.delete();
        } else {
          data['registrationNumber'] = reg;
          if (kind == SelfServiceProfileKind.student) {
            data[pendingRegistrationNumberField] = ApiFieldValue.delete();
          }
        }
      }
      if (isKiuAdmin) {
        if (normalizedTitle != null) {
          data[kiuAdminJobTitleField] = normalizedTitle;
        } else if (clearTitle) {
          data[kiuAdminJobTitleField] = ApiFieldValue.delete();
        }
      }
      await apiStore()
          .collection(ApiCollections.appUsers)
          .doc(uid)
          .set(data, ApiSetOptions(merge: true));

      if (isKiuAdmin && (normalizedTitle != null || clearTitle)) {
        final adminPatch = <String, dynamic>{
          'fullName': name,
          if (reg != null) 'registrationNumber': reg,
        };
        if (normalizedTitle != null) {
          adminPatch[kiuAdminJobTitleField] = normalizedTitle;
        } else if (clearTitle) {
          adminPatch[kiuAdminJobTitleField] = ApiFieldValue.delete();
        }
        await apiStore()
            .collection(ApiCollections.admins)
            .doc(uid)
            .set(adminPatch, ApiSetOptions(merge: true));
        _cachedKiuAdminJobTitle = normalizedTitle;
      }

      _cachedName = name;
      if (reg != null) _cachedReg = reg;

      if (kind == SelfServiceProfileKind.student) {
        final email = StudentAuthEmail.normalizeStudentEmail(user.email ?? '');
        unawaited(_reserveStudentRegistration(
          uid: uid,
          email: email,
          registrationNumber: reg,
          fullName: name,
        ));
      }

      try {
        await user.updateDisplayName(name);
      } catch (_) {}

      unawaited(_persistSessionCache(uid));
      notifyListeners();
      return null;
    } on ApiException catch (fe) {
      if (fe.code == 'permission-denied') {
        return UserFacingErrors.saveProfileFailed;
      }
      return UserFacingErrors.saveProfileFailed;
    } catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          UserFacingErrors.saveProfileFailed;
    }
  }

  /// Sends verification link to student or @kiu.ac.ug staff mailboxes.
  Future<String?> sendEmailVerificationForCurrentUser() async {
    if (!_apiReady) return _apiNotReadyMessage();
    final user = ApiAuth.instance.currentUser;
    if (user == null) return 'You must be signed in.';
    final email = user.email ?? '';
    if (!StudentAuthEmail.isStudentMailbox(email) &&
        !KiuStaffAuthEmail.isStaffMailbox(email)) {
      return 'Email verification is only required for KIU student and staff accounts.';
    }
    try {
      await user.sendEmailVerification();
      clearVerificationEmailQueuedAtSignup();
      return null;
    } on ApiAuthException catch (ex) {
      if (ex.code == 'too-many-requests') {
        if (_verificationEmailQueuedAtSignup) {
          clearVerificationEmailQueuedAtSignup();
          return null;
        }
        return 'Please wait a few minutes before requesting another email.';
      }
      return UserFacingErrors.sanitize(ex.message);
    } catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          UserFacingErrors.genericTryAgain;
    }
  }

  Future<Map<String, String>?> profileForCurrentUser() async {
    final user = ApiAuth.instance.currentUser;
    if (user == null || !_apiReady) return null;
    if (_skipServerRegistrationVerification()) {
      return _cachedProfileMapForUser(user);
    }
    try {
      final doc = await apiStore()
          .collection(ApiCollections.appUsers)
          .doc(user.uid)
          .get();
      final email = _uiVisibleEmail(user.email) ?? '—';
      if (!doc.exists || doc.data() == null) {
        var reg = _cachedReg ?? '—';
        if (reg == '—' &&
            StudentAuthEmail.isStudentMailbox(user.email ?? '')) {
          final fromLink = await _lookupStudentRegistrationFromEmailLink(
            user,
            registrationHint: _cachedReg,
          );
          if (fromLink != null && fromLink.isNotEmpty) {
            reg = fromLink.toUpperCase();
            _cachedReg = fromLink;
          }
        }
        return {
          'email': email,
          'registrationNumber': reg,
          if (_cachedName != null && _cachedName!.isNotEmpty)
            'fullName': _cachedName!,
        };
      }
      final d = doc.data()!;
      final linked = (d['registrationNumber'] as String?)?.trim();
      final pending =
          (d[pendingRegistrationNumberField] as String?)?.trim();
      String reg;
      if (_isStudentAccountProfile(d, user)) {
        reg = (linked != null && linked.isNotEmpty ? linked : pending)
                ?.toUpperCase() ??
            _cachedReg?.toUpperCase() ??
            '—';
        if (reg == '—') {
          final fromLink = await _lookupStudentRegistrationFromEmailLink(
            user,
            registrationHint: linked ?? pending ?? _cachedReg,
          );
          if (fromLink != null && fromLink.isNotEmpty) {
            reg = fromLink.toUpperCase();
            _cachedReg = fromLink;
            _cachedIsStudentProfile = true;
            unawaited(
              _backfillAppUserRegistrationFromEmailLink(
                user,
                fromLink,
                profileData: d,
              ),
            );
          }
        }
      } else {
        final staffSn = (_cachedStaffNumber ??
                (d['staffNumber'] as String?) ??
                linked ??
                pending)
            ?.trim()
            .toUpperCase();
        reg = (staffSn != null && staffSn.isNotEmpty) ? staffSn : '—';
      }
      final name = (d['fullName'] as String?)?.trim();
      String? memberSince;
      final created = d['createdAt'];
      if (created is String) {
        memberSince = created;
      } else if (created is DateTime) {
        memberSince = created.toUtc().toIso8601String();
      }
      return {
        'email': email,
        'registrationNumber': reg,
        if (name != null && name.isNotEmpty) 'fullName': name,
        if (memberSince != null) 'memberSince': memberSince,
        if (KiuAdminJobTitle.normalize(
                d[kiuAdminJobTitleField] as String?) !=
            null)
          kiuAdminJobTitleField: KiuAdminJobTitle.normalize(
            d[kiuAdminJobTitleField] as String?,
          )!,
      };
    } catch (_) {
      final email = _uiVisibleEmail(user.email) ?? '—';
      final staffSn = _cachedStaffNumber?.trim().toUpperCase();
      return {
        'email': email,
        'registrationNumber':
            _cachedReg?.toUpperCase() ?? staffSn ?? '—',
        if (_cachedName != null && _cachedName!.isNotEmpty) 'fullName': _cachedName!,
      };
    }
  }
}

class _StudentRegConflict implements Exception {
  const _StudentRegConflict(this.code);
  final String code;
}
