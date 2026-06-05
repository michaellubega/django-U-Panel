import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../firebase_options.dart';
import 'auth_action_result.dart';
import 'staff_auth_email.dart';
import 'student_auth_email.dart';
import 'student_registration_number.dart';
import 'user_role.dart';
import '../connectivity/app_connectivity.dart';
import '../firebase/firestore_collections.dart';
import '../firebase/u_panel_firestore.dart';
import '../navigation/app_navigator.dart';
import '../session/app_session_reset.dart';

/// Result of [AuthRepository.registerLecturerAccount] / [registerQaStaffAccount].
typedef StaffRegistrationResult = ({String? error, String? staffNumber});

/// Web (JS interop) often wraps the real [FirebaseException] on `error`.
FirebaseException? _unwrapFirebaseException(Object e) {
  if (e is FirebaseException) return e;
  try {
    final dynamic boxed = e;
    final inner = boxed.error;
    if (inner is FirebaseException) return inner;
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

String _formatFirestoreFailure(Object e) {
  final fe = _unwrapFirebaseException(e);
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

bool _isFirestorePermissionDenied(Object e) {
  final fe = _unwrapFirebaseException(e);
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
  final detail = _formatFirestoreFailure(error);
  final uidPart = (currentUid != null && currentUid.trim().isNotEmpty)
      ? currentUid.trim()
      : 'unknown uid';
  if (_isFirestorePermissionDenied(error)) {
    return 'Access denied at $stage (Firestore db: $databaseId, uid: $uidPart). '
        'Ensure rules are deployed to this database and this uid has admins/$uidPart '
        'with isAdmin: true. Raw error: $detail';
  }
  return 'Failed at $stage (Firestore db: $databaseId, uid: $uidPart). '
      'Raw error: $detail';
}

/// Firebase Auth (email + password) with optional profile fields in [app_users/{uid}].
/// Admin role: [admins] / document id = Firebase Auth uid, field [adminIsAdminField].
/// Lecturer role: [lecturers] / document id = Firebase Auth uid, field [lecturerIsLecturerField].
class AuthRepository extends ChangeNotifier {
  AuthRepository._();
  static final AuthRepository instance = AuthRepository._();

  static const adminIsAdminField = 'isAdmin';
  static const adminIsAdminLegacyField = 'isadmin';

  /// Distinguishes QA staff from full administrators in the UI ([admins] collection).
  static const adminRoleField = 'adminRole';
  static const adminRoleQaStaff = 'qa_staff';
  static const adminRoleAdministrator = 'administrator';
  static const lecturerIsLecturerField = 'isLecturer';

  static bool _adminFlagFromData(Map<String, dynamic>? data) {
    if (data == null) return false;
    bool truthy(dynamic v) => v == true || v == 'true' || v == 1;
    return truthy(data[adminIsAdminField]) || truthy(data[adminIsAdminLegacyField]);
  }

  /// Reads [admins/{uid}] and legacy [admin/{uid}], preferring whichever grants admin.
  Future<DocumentSnapshot<Map<String, dynamic>>> _fetchAdminRoleDoc(String uid) async {
    final db = uPanelFirestore();
    DocumentSnapshot<Map<String, dynamic>>? primary;
    DocumentSnapshot<Map<String, dynamic>>? legacy;
    try {
      primary =
          await db.collection(FirestoreCollections.admins).doc(uid).get();
    } catch (_) {}
    try {
      legacy =
          await db.collection(FirestoreCollections.adminsLegacy).doc(uid).get();
    } catch (_) {}

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
    return db.collection(FirestoreCollections.admins).doc(uid).get();
  }

  /// Secondary Firebase app so [createUserWithEmailAndPassword] does not sign out the default session.
  static const _registrationAppName = 'u_panel_auth_registration';

  bool _initialized = false;
  bool get initialized => _initialized;
  bool _forceSignedOut = false;
  bool _signingOut = false;
  int _authenticatingCount = 0;
  int _sessionEpoch = 0;

  /// True while sign-in or registration is in flight (avoids login-screen flash).
  bool get isAuthenticating => _authenticatingCount > 0;

  /// True while [logout] is waiting for Firebase — UI shows a blocking overlay.
  bool get signingOut => _signingOut;

  /// Changes on each sign-out so [AppShell] and tabs are recreated for the next login.
  int get sessionEpoch => _sessionEpoch;

  String? _cachedReg;
  String? _cachedName;
  String? _cachedEmail;
  bool _isAdmin = false;
  bool _isQaStaff = false;
  bool _adminCheckDone = false;

  bool _isLecturer = false;
  bool _lecturerCheckDone = false;
  String? _cachedStaffNumber;

  /// True when reading [admins] / [lecturers] failed with permission-denied (rules not deployed, wrong DB, etc.).
  bool _firestoreRoleCheckDenied = false;

  /// Skips repeat role reads when [authStateChanges] fires many times for the same uid.
  String? _lastRoleHydrateUid;

  int _hydrateGeneration = 0;

  static bool _loggedRoleRulesDeployHint = false;

  StreamSubscription<User?>? _authSub;
  FirebaseAuth? _cachedRegistrationAuth;

  /// Firestore [admins] with `isAdmin: true` (QA staff and full administrators).
  bool get isAdmin => _isAdmin;

  /// QA staff: same privileges as [isAdmin], different [resolvedRole] / UI label.
  bool get isQaStaff => _isQaStaff;

  /// Full administrator (not QA staff).
  bool get isFullAdministrator => _isAdmin && !_isQaStaff;

  bool get adminCheckDone => _adminCheckDone;

  bool get isLecturer => _isLecturer;
  bool get lecturerCheckDone => _lecturerCheckDone;

  /// Resolved role for navigation: staff access wins over lecturer when both apply.
  UserRole get resolvedRole {
    if (_adminCheckDone && _isAdmin) {
      return _isQaStaff ? UserRole.qaStaff : UserRole.admin;
    }
    if (_lecturerCheckDone && _isLecturer) return UserRole.lecturer;
    return UserRole.student;
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

  /// True when role flags have been loaded at least once.
  bool get roleCheckDone => _adminCheckDone && _lecturerCheckDone;

  /// Set when Firestore denied role profile reads (often rules missing on database [upanel]).
  bool get firestoreRoleCheckDenied => _firestoreRoleCheckDenied;

  String? _studentRegistrationConflictMessage;
  Timer? _studentRegConflictSnackTimer;

  static const Duration _studentRegConflictSnackDuration =
      Duration(seconds: 7);

  /// Set when [app_users] registration number conflicts with [student_registrations].
  String? get studentRegistrationConflictMessage =>
      _studentRegistrationConflictMessage;

  /// Bottom snackbar for 30s, then clears (registration / reg-link errors).
  void _presentStudentRegistrationConflict(String message) {
    final text = message.trim();
    if (text.isEmpty) return;
    _studentRegConflictSnackTimer?.cancel();
    _studentRegistrationConflictMessage = text;
    showRootSnackBar(
      text,
      duration: _studentRegConflictSnackDuration,
      isError: true,
    );
    _studentRegConflictSnackTimer = Timer(_studentRegConflictSnackDuration, () {
      clearStudentRegistrationConflictMessage();
    });
    notifyListeners();
  }

  void clearStudentRegistrationConflictMessage() {
    _studentRegConflictSnackTimer?.cancel();
    _studentRegConflictSnackTimer = null;
    if (_studentRegistrationConflictMessage == null) return;
    _studentRegistrationConflictMessage = null;
    hideRootSnackBar();
    notifyListeners();
  }

  /// KIU-#### for signed-in lecturer; null for other users.
  String? get currentStaffNumber => _cachedStaffNumber;

  /// Firebase Auth uid for the signed-in user (for admin grants).
  String? get currentFirebaseUid =>
      _firebaseReady ? FirebaseAuth.instance.currentUser?.uid : null;

  bool get _firebaseReady {
    try {
      return Firebase.apps.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  String _firebaseNotReadyMessage() {
    if (!kIsWeb) {
      switch (defaultTargetPlatform) {
        case TargetPlatform.windows:
        case TargetPlatform.linux:
        case TargetPlatform.macOS:
          return 'Firebase is not configured for this desktop platform. '
              'Run flutterfire configure with desktop platforms enabled, then rebuild the app.';
        default:
          break;
      }
    }
    return 'Firebase is not ready. Check your connection and restart the app.';
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
      'No internet connection. Turn on mobile data or Wi‑Fi, then try again.';

  static const String signOutRequiresInternetMessage =
      'Sign out requires an internet connection. Turn on Wi‑Fi or mobile data, then try again.';

  static bool _looksLikeNetworkFailure(Object ex) {
    final blob = ex.toString().toLowerCase();
    if (ex is FirebaseAuthException) {
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
      return networkUnavailableMessage;
    }
    final raw = ex.toString();
    if (ex is PlatformException) {
      final blob =
          '${ex.code} ${ex.message ?? ''} ${ex.details ?? ''}'.toLowerCase();
      if (blob.contains('network') || blob.contains('unavailable')) {
        return networkUnavailableMessage;
      }
    }
    if (raw.contains('FirebaseAuthHostApi') ||
        raw.contains('firebase_auth_platform_interface') ||
        raw.contains('pigeon')) {
      return 'The device could not complete sign-up with Google/Firebase. Try: '
          'fully stop the app and open it again (hot reload is not enough), update '
          '"Google Play services", or reinstall. In Firebase Console enable Authentication → '
          'Email/Password. Check your email field for an accidental character before the address.';
    }
    return null;
  }

  bool get hasFirebaseSession =>
      _firebaseReady && FirebaseAuth.instance.currentUser != null;

  bool get isLoggedIn =>
      hasFirebaseSession && !_forceSignedOut && !_signingOut;

  void _beginAuthenticating() {
    _authenticatingCount++;
  }

  void _endAuthenticating() {
    if (_authenticatingCount > 0) _authenticatingCount--;
  }

  /// True when signed in with @studmc.kiu.ac.ug and Firebase has not confirmed the mailbox.
  bool get needsStudentEmailVerification {
    if (!_firebaseReady || _forceSignedOut) return false;
    return _needsStudentEmailVerification(FirebaseAuth.instance.currentUser);
  }

  String? _uiVisibleEmail(String? email) {
    final e = email?.trim();
    if (e == null || e.isEmpty) return null;
    return StaffAuthEmail.syntheticEmailToStaffNumber(e) != null ? null : e;
  }

  String? get currentUserEmail => _firebaseReady
      ? _uiVisibleEmail(FirebaseAuth.instance.currentUser?.email)
      : null;

  String? get currentRegistrationNumber => _cachedReg;
  String? get currentFullName => _cachedName;
  String? get currentEmail => _uiVisibleEmail(_cachedEmail);

  Future<void> loadInitialSession() async {
    await _authSub?.cancel();
    _authSub = null;

    if (!_firebaseReady) {
      _forceSignedOut = true;
      _clearCaches();
      _initialized = true;
      _adminCheckDone = true;
      _lecturerCheckDone = true;
      notifyListeners();
      return;
    }

    _authSub = FirebaseAuth.instance.authStateChanges().listen(
      (user) async {
        await _hydrateUser(user);
        notifyListeners();
      },
      onError: (Object e, StackTrace st) {
        if (kDebugMode) {
          debugPrint('AuthRepository authStateChanges: $e');
          debugPrint('$st');
        }
      },
    );

    await _hydrateUser(FirebaseAuth.instance.currentUser);
    _initialized = true;
    notifyListeners();
  }

  void _clearCaches() {
    _cachedReg = null;
    _cachedName = null;
    _cachedEmail = null;
    _isAdmin = false;
    _isQaStaff = false;
    _adminCheckDone = true;
    _isLecturer = false;
    _lecturerCheckDone = true;
    _cachedStaffNumber = null;
    _firestoreRoleCheckDenied = false;
    _lastRoleHydrateUid = null;
    clearStudentRegistrationConflictMessage();
  }

  void _logRoleRulesDeployHintOnce() {
    if (!kDebugMode || _loggedRoleRulesDeployHint) return;
    _loggedRoleRulesDeployHint = true;
    debugPrint(
      'AuthRepository: role profile read denied — deploy firestore.rules to '
      'database "$uPanelFirestoreDatabaseId" (firebase deploy --only firestore).',
    );
  }

  Future<void> _hydrateUser(User? user) async {
    if (_signingOut) {
      if (user == null) {
        _forceSignedOut = true;
        _clearCaches();
      }
      return;
    }

    if (user == null) {
      // authStateChanges can emit null while currentUser is still set — ignore.
      if (FirebaseAuth.instance.currentUser != null) return;
      _forceSignedOut = true;
      _clearCaches();
      return;
    }

    if (_forceSignedOut) {
      if (FirebaseAuth.instance.currentUser != null) {
        _forceSignedOut = false;
      } else {
        return;
      }
    }

    final gen = ++_hydrateGeneration;
    final uid = user.uid;

    _forceSignedOut = false;
    _cachedEmail = _uiVisibleEmail(user.email);

    try {
      await user.getIdToken();
    } catch (_) {}

    if (gen != _hydrateGeneration) return;

    try {
      final doc = await uPanelFirestore()
          .collection(FirestoreCollections.appUsers)
          .doc(uid)
          .get();
      if (doc.exists && doc.data() != null) {
        final d = doc.data()!;
        final r = (d['registrationNumber'] as String?)?.trim();
        _cachedReg = (r != null && r.isNotEmpty) ? r : null;
        final n = (d['fullName'] as String?)?.trim();
        _cachedName = (n != null && n.isNotEmpty) ? n : null;
        final profileEmail =
            (d['email'] as String?)?.trim().toLowerCase() ?? user.email ?? '';
        if (_cachedReg != null &&
            profileEmail.isNotEmpty &&
            StudentAuthEmail.isStudentMailbox(profileEmail)) {
          final linkErr = await _reserveStudentRegistration(
            uid: uid,
            email: StudentAuthEmail.normalizeStudentEmail(profileEmail),
            registrationNumber: _cachedReg!,
          );
          if (linkErr != null) {
            if (_studentRegistrationConflictMessage != linkErr) {
              _presentStudentRegistrationConflict(linkErr);
            }
          } else {
            clearStudentRegistrationConflictMessage();
          }
        } else {
          clearStudentRegistrationConflictMessage();
        }
      } else {
        _cachedReg = null;
        _cachedName = null;
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AuthRepository._hydrateUser profile: $e');
        debugPrint('$st');
      }
      // Keep previously cached reg/name on transient network/read failures.
    }

    if (gen != _hydrateGeneration) return;

    final skipRoleReads =
        _lastRoleHydrateUid == uid && _adminCheckDone && _lecturerCheckDone;
    if (!skipRoleReads) {
      await Future.wait([
        _refreshIsAdmin(uid),
        _refreshIsLecturer(uid),
      ]);
      if (gen != _hydrateGeneration) return;
      _lastRoleHydrateUid = uid;
    }
  }

  Future<void> _refreshIsAdmin(String uid) async {
    if (!_firebaseReady) {
      _isAdmin = false;
      _isQaStaff = false;
      _adminCheckDone = true;
      return;
    }
    try {
      final snap = await _fetchAdminRoleDoc(uid);
      final data = snap.data();
      _firestoreRoleCheckDenied = false;
      _isAdmin = snap.exists && _adminFlagFromData(data);
      _isQaStaff = _isAdmin && _adminDocIsQaStaff(data);
      if (_isAdmin && snap.exists && data != null) {
        final canonical = data[adminIsAdminField];
        if (canonical != true) {
          unawaited(
            snap.reference.set(
              <String, dynamic>{adminIsAdminField: true},
              SetOptions(merge: true),
            ),
          );
        }
        if (_isQaStaff && data[adminRoleField] == null) {
          unawaited(
            snap.reference.set(
              <String, dynamic>{adminRoleField: adminRoleQaStaff},
              SetOptions(merge: true),
            ),
          );
        }
      }
    } catch (e, st) {
      if (_isFirestorePermissionDenied(e)) {
        _firestoreRoleCheckDenied = true;
        _logRoleRulesDeployHintOnce();
      } else if (kDebugMode) {
        debugPrint('AuthRepository._refreshIsAdmin: $e');
        debugPrint('$st');
      }
      _isAdmin = false;
      _isQaStaff = false;
    }
    _adminCheckDone = true;
  }

  Future<void> _refreshIsLecturer(String uid) async {
    if (!_firebaseReady) {
      _isLecturer = false;
      _cachedStaffNumber = null;
      _lecturerCheckDone = true;
      return;
    }
    try {
      final snap = await uPanelFirestore()
          .collection(FirestoreCollections.lecturers)
          .doc(uid)
          .get();
      final data = snap.data();
      _isLecturer = snap.exists &&
          data != null &&
          data[lecturerIsLecturerField] == true;
      final sn = (data?['staffNumber'] as String?)?.trim().toUpperCase();
      _cachedStaffNumber =
          (sn != null && sn.isNotEmpty) ? sn : null;
    } catch (e, st) {
      if (_isFirestorePermissionDenied(e)) {
        _firestoreRoleCheckDenied = true;
        _logRoleRulesDeployHintOnce();
      } else if (kDebugMode) {
        debugPrint('AuthRepository._refreshIsLecturer: $e');
        debugPrint('$st');
      }
      _isLecturer = false;
      _cachedStaffNumber = null;
    }
    _lecturerCheckDone = true;
  }

  static String _loginEmailForFirebase(String resolvedNormalized) {
    var e = normalizeEmail(resolvedNormalized);
    if (StudentAuthEmail.isStudentMailbox(e)) {
      e = StudentAuthEmail.normalizeStudentEmail(e);
    }
    return e;
  }

  bool _needsStudentEmailVerification(User? user) {
    if (user == null) return false;
    final email = user.email ?? '';
    return StudentAuthEmail.isStudentMailbox(email) && !user.emailVerified;
  }

  /// Sends Firebase verification link to the signed-in student mailbox.
  Future<String?> sendStudentEmailVerification() async {
    if (!_firebaseReady) return _firebaseNotReadyMessage();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return 'You must be signed in.';
    if (!StudentAuthEmail.isStudentMailbox(user.email ?? '')) {
      return 'Email verification is only required for KIU student accounts.';
    }
    try {
      await user.sendEmailVerification();
      return null;
    } on FirebaseAuthException catch (ex) {
      if (ex.code == 'too-many-requests') {
        return 'Please wait a few minutes before requesting another email.';
      }
      return ex.message ?? ex.code;
    } on PlatformException catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          'Could not send verification email: ${ex.message ?? ex.code}';
    } catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          'Could not send verification email: $ex';
    }
  }

  /// Sends a Firebase password-reset link to a student [@studmc.kiu.ac.ug] mailbox.
  /// Returns null on success. Staff [KIU-####] logins are not supported (no real inbox).
  Future<String?> sendPasswordResetEmail({required String rawLogin}) async {
    if (!_firebaseReady) return _firebaseNotReadyMessage();
    if (AppConnectivity.instance.initialized &&
        !AppConnectivity.instance.isOnline) {
      return networkUnavailableMessage;
    }
    if (StaffAuthEmail.looksLikeStaffNumberOnly(rawLogin)) {
      return 'Staff accounts (KIU-####) cannot reset a password by email. '
          'Ask your administrator, or sign in and change your password under Settings.';
    }
    final resolved = StaffAuthEmail.resolveLoginEmail(rawLogin) ?? '';
    final e = _loginEmailForFirebase(resolved);
    if (e.isEmpty) {
      return 'Enter your KIU school email.';
    }
    if (!e.contains('@')) {
      return 'Enter your KIU school email (e.g. ${StudentAuthEmail.exampleEmail}).';
    }
    if (StaffAuthEmail.syntheticEmailToStaffNumber(e) != null) {
      return 'Staff accounts (KIU-####) cannot reset a password by email. '
          'Ask your administrator, or sign in and change your password under Settings.';
    }
    final schoolErr = StudentAuthEmail.validateLoginFormat(rawLogin);
    if (schoolErr != null) return schoolErr;
    final em = StudentAuthEmail.normalizeStudentEmail(rawLogin);
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: em);
      return null;
    } on FirebaseAuthException catch (ex) {
      if (ex.code == 'user-not-found' || ex.code == 'invalid-email') {
        // Avoid revealing whether the account exists.
        return null;
      }
      if (ex.code == 'too-many-requests') {
        return 'Too many requests. Wait a few minutes, then try again.';
      }
      return ex.message ?? ex.code;
    } on PlatformException catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          'Could not send reset email: ${ex.message ?? ex.code}';
    } catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          'Could not send reset email: $ex';
    }
  }

  /// Reloads the Auth user and returns whether the student mailbox is verified.
  Future<bool> refreshStudentEmailVerified() async {
    if (!_firebaseReady) return false;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    await user.reload();
    try {
      await user.getIdToken(true);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AuthRepository.refreshStudentEmailVerified token: $e');
      }
    }
    final verified = FirebaseAuth.instance.currentUser?.emailVerified ?? false;
    if (kDebugMode) {
      debugPrint(
        'AuthRepository emailVerified=$verified email=${user.email}',
      );
    }
    notifyListeners();
    return verified;
  }

  /// Returns [AuthActionResult.ok] on success. Student accounts may require email verification first.
  Future<AuthActionResult> signInWithEmail({
    required String email,
    required String password,
  }) async {
    if (!_firebaseReady) {
      return AuthActionResult(error: _firebaseNotReadyMessage());
    }
    final resolved = StaffAuthEmail.resolveLoginEmail(email) ?? '';
    final e = _loginEmailForFirebase(resolved);
    if (e.isEmpty) return const AuthActionResult(error: 'Enter your email or staff ID (KIU-####).');
    if (!e.contains('@')) {
      if (StaffAuthEmail.looksLikeStaffNumberOnly(email)) {
        return const AuthActionResult(
          error: 'Invalid staff ID. Use format KIU-#### (e.g. KIU-0001).',
        );
      }
      return const AuthActionResult(error: 'Enter a valid email address.');
    }
    if (password.isEmpty) {
      return const AuthActionResult(error: 'Enter your password.');
    }
    final isStaffLogin = StaffAuthEmail.syntheticEmailToStaffNumber(e) != null ||
        StaffAuthEmail.looksLikeStaffNumberOnly(email);
    if (e.contains('@') && !isStaffLogin) {
      final schoolErr = StudentAuthEmail.validateLoginFormat(email);
      if (schoolErr != null) {
        return AuthActionResult(error: schoolErr);
      }
    }
    if (AppConnectivity.instance.initialized &&
        !AppConnectivity.instance.isOnline) {
      return AuthActionResult(error: networkUnavailableMessage);
    }
    _beginAuthenticating();
    notifyListeners();
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: e,
        password: password,
      );
      _forceSignedOut = false;
      final signedIn = FirebaseAuth.instance.currentUser;
      if (signedIn != null) {
        await signedIn.reload();
        try {
          await signedIn.getIdToken(true);
        } catch (_) {}
        await _hydrateUser(signedIn);
        notifyListeners();
      }
      if (_needsStudentEmailVerification(FirebaseAuth.instance.currentUser)) {
        return const AuthActionResult(needsEmailVerification: true);
      }
      return const AuthActionResult();
    } on FirebaseAuthException catch (ex) {
      return AuthActionResult(error: _mapAuthError(ex));
    } on PlatformException catch (ex) {
      return AuthActionResult(
        error: _describeAuthChannelFailure(ex) ??
            'Could not sign in: ${ex.message ?? ex.code}',
      );
    } catch (ex) {
      return AuthActionResult(
        error: _describeAuthChannelFailure(ex) ?? 'Could not sign in: $ex',
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
  Future<String?> _reserveStudentRegistration({
    required String uid,
    required String email,
    required String registrationNumber,
  }) async {
    final reg = StudentRegistrationNumber.normalize(registrationNumber);
    final em = StudentAuthEmail.normalizeStudentEmail(email);
    final db = uPanelFirestore();
    final regRef = db
        .collection(FirestoreCollections.studentRegistrations)
        .doc(reg);
    try {
      await db.runTransaction<void>((transaction) async {
        final existing = await transaction.get(regRef);
        if (existing.exists) {
          final d = existing.data();
          final ownerUid = (d?['uid'] as String?)?.trim() ?? '';
          final ownerEmail =
              StudentAuthEmail.normalizeStudentEmail((d?['email'] as String?) ?? '');
          if (ownerUid.isNotEmpty && ownerUid != uid) {
            throw const _StudentRegConflict('taken');
          }
          if (ownerEmail.isNotEmpty && ownerEmail != em) {
            throw const _StudentRegConflict('email_mismatch');
          }
          if (ownerUid == uid && ownerEmail == em) {
            return;
          }
        }
        transaction.set(regRef, <String, dynamic>{
          'uid': uid,
          'email': em,
          'registrationNumber': reg,
          'createdAt': FieldValue.serverTimestamp(),
        });
      });
      return null;
    } on _StudentRegConflict catch (c) {
      return _studentRegConflictMessage(c, reg);
    } on FirebaseException catch (fe) {
      if (fe.code == 'permission-denied') {
        if (kDebugMode) {
          debugPrint(
            'AuthRepository._reserveStudentRegistration permission-denied '
            '(db=$uPanelFirestoreDatabaseId, reg=$reg, uid=$uid): ${fe.message}',
          );
        }
        return 'Could not link your registration number (Firestore access denied). '
            'Ask ICT to deploy the latest firestore.rules to the '
            '"$uPanelFirestoreDatabaseId" database, then try again in a few minutes. '
            'If you already registered this number, sign in with the same school email instead.';
      }
      return 'Could not verify your registration number: ${fe.message ?? fe.code}';
    } catch (e) {
      return 'Could not verify your registration number: $e';
    }
  }

  /// Creates [app_users/{uid}] and sends a verification link to @studmc.kiu.ac.ug mailboxes.
  Future<AuthActionResult> registerWithEmail({
    required String email,
    required String fullName,
    required String password,
    required String registrationNumber,
  }) async {
    if (!_firebaseReady) {
      return AuthActionResult(error: _firebaseNotReadyMessage());
    }
    final formatErr = StudentAuthEmail.validateFormat(email);
    if (formatErr != null) {
      return AuthActionResult(error: formatErr);
    }
    final em = StudentAuthEmail.normalizeStudentEmail(email);
    final regErr = StudentRegistrationNumber.validateFormat(registrationNumber);
    if (regErr != null) {
      return AuthActionResult(error: regErr);
    }
    final reg = StudentRegistrationNumber.normalize(registrationNumber);
    final name = fullName.trim();
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
    UserCredential? cred;
    _beginAuthenticating();
    notifyListeners();
    try {
      cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: em,
        password: password,
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

      final linkErr = await _reserveStudentRegistration(
        uid: uid,
        email: em,
        registrationNumber: reg,
      );
      if (linkErr != null) {
        try {
          await user.delete();
        } catch (_) {}
        _presentStudentRegistrationConflict(linkErr);
        return AuthActionResult(error: linkErr);
      }
      clearStudentRegistrationConflictMessage();

      await uPanelFirestore().collection(FirestoreCollections.appUsers).doc(uid).set({
        'email': em,
        'fullName': name,
        'registrationNumber': reg,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      try {
        await user.updateDisplayName(name);
      } catch (_) {}

      try {
        await user.sendEmailVerification();
      } on FirebaseAuthException catch (ex) {
        try {
          await user.delete();
        } catch (_) {}
        if (ex.code == 'too-many-requests') {
          return const AuthActionResult(
            error:
                'Could not send verification email (too many requests). Try again shortly.',
          );
        }
        return AuthActionResult(
          error: ex.message ?? 'Could not send verification email.',
        );
      }

      _forceSignedOut = false;
      await _hydrateUser(user);
      notifyListeners();
      return const AuthActionResult(needsEmailVerification: true);
    } on FirebaseAuthException catch (ex) {
      return AuthActionResult(error: _mapAuthError(ex));
    } on PlatformException catch (ex) {
      return AuthActionResult(
        error: _describeAuthChannelFailure(ex) ??
            'Could not create account: ${ex.message ?? ex.code}',
      );
    } on FirebaseException catch (fe) {
      try {
        await cred?.user?.delete();
      } catch (_) {
        /* cleanup best-effort */
      }
      if (fe.code == 'permission-denied') {
        return const AuthActionResult(
          error:
              'Could not save your profile (access denied). Deploy Firestore rules to the '
              'same database the app uses (upanel), and ensure Authentication → Email/Password is enabled.',
        );
      }
      return AuthActionResult(
        error: 'Could not save your profile: ${fe.message ?? fe.code}',
      );
    } catch (ex) {
      try {
        await cred?.user?.delete();
      } catch (_) {
        /* cleanup best-effort */
      }
      return AuthActionResult(
        error: _describeAuthChannelFailure(ex) ?? 'Could not create account: $ex',
      );
    } finally {
      _endAuthenticating();
      notifyListeners();
    }
  }

  String _mapAuthError(FirebaseAuthException ex) {
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
      case 'network-request-failed':
      case 'unavailable':
        return networkUnavailableMessage;
      default:
        return ex.message ?? ex.code;
    }
  }

  Future<FirebaseAuth> _registrationAuth() async {
    final cached = _cachedRegistrationAuth;
    if (cached != null) return cached;
    try {
      _cachedRegistrationAuth =
          FirebaseAuth.instanceFor(app: Firebase.app(_registrationAppName));
      return _cachedRegistrationAuth!;
    } catch (_) {
      try {
        final app = await Firebase.initializeApp(
          name: _registrationAppName,
          options: DefaultFirebaseOptions.currentPlatform,
        );
        _cachedRegistrationAuth = FirebaseAuth.instanceFor(app: app);
        return _cachedRegistrationAuth!;
      } on FirebaseException catch (e) {
        if (e.code == 'duplicate-app') {
          _cachedRegistrationAuth = FirebaseAuth.instanceFor(
            app: Firebase.app(_registrationAppName),
          );
          return _cachedRegistrationAuth!;
        }
        rethrow;
      }
    }
  }

  /// Refreshes admin flag then returns an error message if the caller is not an admin.
  Future<String?> _requireAdmin({bool skipRefreshIfKnown = false}) async {
    if (!_firebaseReady) {
      return _firebaseNotReadyMessage();
    }
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return 'You must be signed in.';
    if (!skipRefreshIfKnown || !_adminCheckDone || !_isAdmin) {
      await _refreshIsAdmin(u.uid);
    }
    if (!_isAdmin) {
      if (_firestoreRoleCheckDenied) {
        return 'Firestore denied reading your admin profile (permission-denied). '
            'Deploy security rules to the "$uPanelFirestoreDatabaseId" database '
            '(run `firebase deploy --only firestore` from the project root, '
            'or paste firestore.rules in Firebase Console → Firestore → Rules). '
            'Then reload the app.';
      }
      return 'Only admins can create staff accounts or grant admin access. '
          'Your account needs admins/${u.uid} with isAdmin: true in Firestore '
          '(or ask another admin to grant access in Settings).';
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
    _clearCaches();
    AppSessionReset.onSignOutImmediate();
    notifyListeners();

    try {
      if (_firebaseReady) {
        try {
          await FirebaseAuth.instance.signOut();
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
      unawaited(AppSessionReset.onSignOutDeferred());
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
    if (!_firebaseReady) {
      return _firebaseNotReadyMessage();
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return 'You must be signed in.';
    final email = user.email?.trim();
    if (email == null || email.isEmpty) {
      return 'This account has no email/password sign-in method.';
    }
    final current = currentPassword.trim();
    if (current.isEmpty) return 'Enter your current password.';
    if (newPassword.length < 6) {
      return 'New password must be at least 6 characters.';
    }
    try {
      final cred = EmailAuthProvider.credential(
        email: email,
        password: current,
      );
      await user.reauthenticateWithCredential(cred);
      await user.updatePassword(newPassword);
      return null;
    } on FirebaseAuthException catch (ex) {
      return _mapAuthError(ex);
    } on PlatformException catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          'Could not change password: ${ex.message ?? ex.code}';
    } catch (ex) {
      return _describeAuthChannelFailure(ex) ??
          'Could not change password: $ex';
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
    if (uid.isEmpty) return 'Enter the other user’s Firebase user id (UID).';
    if (uid.contains('/') || uid.contains('..')) {
      return 'Invalid user id.';
    }
    try {
      await uPanelFirestore().collection(FirestoreCollections.admins).doc(uid).set(
        <String, dynamic>{
          adminIsAdminField: isAdmin,
          if (isAdmin) adminRoleField: adminRoleAdministrator,
          'grantedBy': FirebaseAuth.instance.currentUser!.uid,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      if (uid == FirebaseAuth.instance.currentUser!.uid) {
        await _refreshIsAdmin(uid);
      }
      return null;
    } on FirebaseException catch (fe) {
      if (fe.code == 'permission-denied') {
        return 'Access denied. Deploy updated Firestore rules for the admins collection.';
      }
      return fe.message ?? fe.code;
    } catch (ex) {
      return '$ex';
    }
  }

  /// Creates a new Firebase Auth user (via a secondary Auth app so your session stays signed in),
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
    final granter = FirebaseAuth.instance.currentUser;
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
    UserCredential? cred;
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

      await uPanelFirestore().collection(FirestoreCollections.appUsers).doc(newUid).set({
        'email': em,
        'registrationNumber': _normalizeReg(reg),
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await uPanelFirestore().collection(FirestoreCollections.admins).doc(newUid).set(
        <String, dynamic>{
          adminIsAdminField: true,
          adminRoleField: adminRoleAdministrator,
          'grantedBy': granterUid,
          'createdAt': FieldValue.serverTimestamp(),
          'email': em,
          'registrationNumber': _normalizeReg(reg),
        },
        SetOptions(merge: true),
      );

      await regAuth.signOut();
      return null;
    } on FirebaseAuthException catch (ex) {
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
          'Could not create account: ${ex.message ?? ex.code}';
    } on FirebaseException catch (fe) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      try {
        await regAuth.signOut();
      } catch (_) {}
      if (fe.code == 'permission-denied') {
        return 'Could not save profile or admin record (access denied). Deploy Firestore rules.';
      }
      return 'Could not save: ${fe.message ?? fe.code}';
    } catch (ex) {
      try {
        await cred?.user?.delete();
      } catch (_) {}
      try {
        await regAuth.signOut();
      } catch (_) {}
      return _describeAuthChannelFailure(ex) ?? 'Could not create account: $ex';
    }
  }

  /// Allocates the next free `KIU-####` using [meta/lecturer_staff_counter] and
  /// skipping any [staff_numbers] docs that already exist (orphans / partial writes).
  ///
  /// Returns `(null, message)` on failure so callers can show [FirebaseException.code].
  Future<({String? staffNumber, String? errorMessage})>
      _allocateNextStaffNumberInTransaction() async {
    final db = uPanelFirestore();
    final metaRef = db
        .collection(FirestoreCollections.meta)
        .doc(FirestoreCollections.lecturerStaffCounterDocId);
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
              db.collection(FirestoreCollections.staffNumbers).doc(staffNumber);
          final staffSnap = await transaction.get(staffRef);
          if (!staffSnap.exists) {
            transaction.set(
              metaRef,
              <String, dynamic>{
                'next': next + 1,
                'updatedAt': FieldValue.serverTimestamp(),
              },
              SetOptions(merge: true),
            );
            transaction.set(staffRef, <String, dynamic>{
              'pending': true,
              'createdAt': FieldValue.serverTimestamp(),
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
          'AuthRepository._allocateNextStaffNumberInTransaction: ${_formatFirestoreFailure(e)}',
        );
        debugPrint('$st');
      }
      final uid = FirebaseAuth.instance.currentUser?.uid;
      return (
        staffNumber: null,
        errorMessage: _formatStaffWriteFailure(
          stage: 'allocating staff number (meta/lecturer_staff_counter)',
          error: e,
          databaseId: uPanelFirestoreDatabaseId,
          currentUid: uid,
        ),
      );
    }
  }

  /// Creates lecturer Firebase Auth (synthetic email), [app_users], [lecturers],
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
    final granter = FirebaseAuth.instance.currentUser;
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
          error: alloc.errorMessage ??
              'Could not allocate a staff number. Check Firestore rules for '
              'meta/lecturer_staff_counter and staff_numbers, then deploy rules.',
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

    final db = uPanelFirestore();
    final staffLockRef =
        db.collection(FirestoreCollections.staffNumbers).doc(staffNumber);

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
            'createdAt': FieldValue.serverTimestamp(),
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
    UserCredential? cred;
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
          db.collection(FirestoreCollections.appUsers).doc(newUid),
          <String, dynamic>{
            'email': syntheticEmail,
            'registrationNumber': staffNumber,
            'staffNumber': staffNumber,
            'fullName': name,
            'createdAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
        batch.set(
          db.collection(FirestoreCollections.lecturers).doc(newUid),
          <String, dynamic>{
            lecturerIsLecturerField: true,
            'staffNumber': staffNumber,
            'loginEmail': syntheticEmail,
            'fullName': name,
            'grantedBy': granterUid,
            'createdAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
        batch.set(
          staffLockRef,
          <String, dynamic>{
            'uid': newUid,
            'staffNumber': staffNumber,
            'fullName': name,
            'assignedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
        await batch.commit();
      } catch (e) {
        throw StateError(_formatStaffWriteFailure(
          stage: 'writing lecturer profile (app_users, lecturers, staff_numbers)',
          error: e,
          databaseId: uPanelFirestoreDatabaseId,
          currentUid: granterUid,
        ));
      }

      unawaited(regAuth.signOut());
      return (error: null, staffNumber: staffNumber);
    } on FirebaseAuthException catch (ex) {
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
            'Could not create lecturer: ${ex.message ?? ex.code}',
        staffNumber: null,
      );
    } on FirebaseException catch (fe) {
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
          error: 'Could not save lecturer (access denied). Deploy Firestore rules.',
          staffNumber: null,
        );
      }
      return (
        error: 'Could not save lecturer: ${fe.message ?? fe.code}',
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
            'Could not create lecturer: ${ex.toString().replaceFirst('Bad state: ', '')}',
        staffNumber: null,
      );
    }
  }

  /// Creates QA staff Firebase Auth (same synthetic `KIU-####` scheme as lecturers).
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
  }) async {
    return _registerStaffAdminAccount(
      fullName: fullName,
      manualStaffNumber: manualStaffNumber,
      adminRole: adminRoleAdministrator,
      roleLabel: 'administrator',
      requireFullAdministrator: true,
    );
  }

  Future<StaffRegistrationResult> _registerStaffAdminAccount({
    required String fullName,
    String? manualStaffNumber,
    required String adminRole,
    required String roleLabel,
    required bool requireFullAdministrator,
  }) async {
    final name = fullName.trim();
    if (name.isEmpty) {
      return (error: 'Enter the staff member\'s name.', staffNumber: null);
    }
    final gate = requireFullAdministrator
        ? await _requireFullAdministrator(skipRefreshIfKnown: true)
        : await _requireAdmin(skipRefreshIfKnown: true);
    if (gate != null) return (error: gate, staffNumber: null);
    final granter = FirebaseAuth.instance.currentUser;
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
          error: alloc.errorMessage ??
              'Could not allocate a staff number. Check Firestore rules for '
              'meta/lecturer_staff_counter and staff_numbers, then deploy rules.',
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

    final db = uPanelFirestore();
    final staffLockRef =
        db.collection(FirestoreCollections.staffNumbers).doc(staffNumber);

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
            'createdAt': FieldValue.serverTimestamp(),
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
    UserCredential? cred;
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
          db.collection(FirestoreCollections.appUsers).doc(newUid),
          <String, dynamic>{
            'email': syntheticEmail,
            'registrationNumber': _normalizeReg(staffNumber),
            'staffNumber': staffNumber,
            'fullName': name,
            'createdAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
        batch.set(
          db.collection(FirestoreCollections.admins).doc(newUid),
          <String, dynamic>{
            adminIsAdminField: true,
            adminRoleField: adminRole,
            'grantedBy': granterUid,
            'createdAt': FieldValue.serverTimestamp(),
            'email': syntheticEmail,
            'registrationNumber': _normalizeReg(staffNumber),
            'staffNumber': staffNumber,
            'fullName': name,
          },
          SetOptions(merge: true),
        );
        batch.set(
          staffLockRef,
          <String, dynamic>{
            'uid': newUid,
            'staffNumber': staffNumber,
            'fullName': name,
            'assignedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
        await batch.commit();
      } catch (e) {
        throw StateError(_formatStaffWriteFailure(
          stage: 'writing $roleLabel profile (app_users, admins, staff_numbers)',
          error: e,
          databaseId: uPanelFirestoreDatabaseId,
          currentUid: granterUid,
        ));
      }

      unawaited(regAuth.signOut());
      return (error: null, staffNumber: staffNumber);
    } on FirebaseAuthException catch (ex) {
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
            'Could not create $roleLabel: ${ex.message ?? ex.code}',
        staffNumber: null,
      );
    } on FirebaseException catch (fe) {
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
              'Could not save $roleLabel (access denied). Deploy Firestore rules.',
          staffNumber: null,
        );
      }
      return (
        error: 'Could not save $roleLabel: ${fe.message ?? fe.code}',
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
            'Could not create $roleLabel: ${ex.toString().replaceFirst('Bad state: ', '')}',
        staffNumber: null,
      );
    }
  }

  Future<Map<String, String>?> profileForCurrentUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !_firebaseReady) return null;
    try {
      final doc = await uPanelFirestore()
          .collection(FirestoreCollections.appUsers)
          .doc(user.uid)
          .get();
      final email = _uiVisibleEmail(user.email) ?? '—';
      if (!doc.exists || doc.data() == null) {
        return {
          'email': email,
          'registrationNumber': _cachedReg ?? '—',
          if (_cachedName != null && _cachedName!.isNotEmpty)
            'fullName': _cachedName!,
        };
      }
      final d = doc.data()!;
      final reg =
          (d['registrationNumber'] as String?)?.trim().toUpperCase() ?? '—';
      final name = (d['fullName'] as String?)?.trim();
      String? memberSince;
      final created = d['createdAt'];
      if (created is Timestamp) {
        memberSince = created.toDate().toIso8601String();
      }
      return {
        'email': email,
        'registrationNumber': reg,
        if (name != null && name.isNotEmpty) 'fullName': name,
        if (memberSince != null) 'memberSince': memberSince,
      };
    } catch (_) {
      return {
        'email': _uiVisibleEmail(user.email) ?? '—',
        'registrationNumber': _cachedReg ?? '—',
        if (_cachedName != null && _cachedName!.isNotEmpty) 'fullName': _cachedName!,
      };
    }
  }
}

class _StudentRegConflict implements Exception {
  const _StudentRegConflict(this.code);
  final String code;
}
