/// Plain-language errors for production UI — never mention Firebase, Firestore,
/// security rules, or deployment commands.
abstract final class UserFacingErrors {
  static const networkUnavailable =
      'No internet connection. Turn on mobile data or Wi‑Fi, then try again.';

  /// Shown when the web app (HTTPS) cannot reach an HTTP-only API (browser blocks it).
  static const secureWebInsecureApi =
      'The web app cannot reach the server securely yet. '
      'Use https://kiu.orion13.us/app/ after HTTPS is enabled, or https://api.orion13.us/app/. '
      'Ask ICT to finish Cloudflare setup for api.orion13.us.';

  static const apiConnectionBlocked =
      'Could not reach the server. Check your connection, then try again. '
      'Web: https://kiu.orion13.us/app/ — API: https://api.orion13.us/api/health/';

  static const serviceUnavailable =
      'The service is temporarily unavailable. Check your connection, restart the app, and try again.';

  static const accessDenied =
      'You do not have permission to complete this action. Contact ICT support if this continues.';

  static const registrationLinkFailed =
      'Could not link your registration number. Try again in a few minutes. '
      'If you already registered this number, sign in with the same school email instead.';

  static const registrationVerifyFailed =
      'Could not verify your registration number. Try again shortly.';

  static const registrationVerifyGeneric =
      'Could not verify your registration number. Please try again.';

  static const backendNotReady =
      'The app could not connect to the server. Check your connection and restart the app.';

  static const backendNotReadyDesktop =
      'This app is not set up for this computer yet. Contact ICT support.';

  static const genericTryAgain = 'Something went wrong. Please try again.';

  static const adminOnly =
      'Only administrators can perform this action. Ask an administrator for help.';

  static const adminProfileUnavailable =
      'Could not verify your administrator access. Contact ICT support if this continues.';

  static const notAdminForStaffCreation =
      'Only administrators can create staff accounts or grant admin access. '
      'Ask an administrator for help in Settings.';

  static const signInChannelFailure =
      'Sign-in could not complete on this device. Fully close the app and open it again, '
      'update Google Play services if prompted, or reinstall. '
      'Also check your email field for an accidental character before the address.';

  static const saveProfileFailed =
      'Could not save your profile. Try again later or contact ICT support.';

  static const saveAccountFailed =
      'Could not save the account. Contact ICT support if this continues.';

  static const campusAreaLoadFailed =
      'Could not load the campus check-in area. Try again later or contact ICT support.';

  static const campusCheckInFailed =
      'Could not save campus check-in. Contact ICT support if this continues.';

  static const campusAreaSaveFailed =
      'Could not save the campus area. Contact ICT support if this continues.';

  static const staffRoleLoadFailed =
      'Could not load your staff role. Restart the app and try again, or contact ICT support.';

  static const staffNumberAllocateFailed =
      'Could not allocate a staff number. Try again later or contact ICT support.';

  static const invalidUserId =
      'Enter the other person\'s user id from their account settings.';

  static String forPermissionDenied({String? fallback}) =>
      fallback ?? accessDenied;

  static String? forErrorCode(String? code, {String? fallback}) {
    final c = code?.trim().toLowerCase() ?? '';
    switch (c) {
      case 'permission-denied':
        return accessDenied;
      case 'unavailable':
      case 'network-request-failed':
        return networkUnavailable;
      default:
        return fallback;
    }
  }

  /// Strips backend jargon from text that might be shown to users.
  static String sanitize(String? raw, {String fallback = genericTryAgain}) {
    if (raw == null || raw.trim().isEmpty) return fallback;
    final lower = raw.toLowerCase();
    if (lower.contains('firebase') ||
        lower.contains('firestore') ||
        lower.contains('permission-denied') ||
        lower.contains('firestore.rules') ||
        lower.contains('deploy') ||
        lower.contains('cloud firestore') ||
        lower.contains('google.cloud') ||
        lower.contains('admins/{') ||
        lower.contains('firebaseapp')) {
      return fallback;
    }
    return raw.trim();
  }
}
