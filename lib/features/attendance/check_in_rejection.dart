import 'check_in_outcome.dart';



/// Shown when this phone already checked in (or queued) for another student.

const String deviceAlreadyUsedUserMessage =

    'Device already signed in for another student.';



/// Server/client categories for a failed check-in attempt.

enum CheckInRejectionCategory {

  none,

  deviceAlreadyUsed,

  sessionMismatch,

  rosterOrSignIn,

  other,

}



CheckInRejectionCategory categorizeCheckInRejectionReason(String? reason) {

  final r = reason?.trim().toLowerCase() ?? '';

  if (r.isEmpty) return CheckInRejectionCategory.none;

  if (r.contains('device already used') ||

      r.contains('device already submitted') ||

      r.contains('another student already used') ||

      (r.contains('device') && r.contains('another student'))) {

    return CheckInRejectionCategory.deviceAlreadyUsed;

  }

  if (r.contains('outside session time') ||

      r.contains('outside class location') ||

      r.contains('outside_geofence') ||

      r.contains('outside geofence') ||

      r.contains('session does not match') ||

      r.contains('session code not found') ||

      r.contains('invalid gps') ||

      r.contains('captured outside session time')) {

    return CheckInRejectionCategory.sessionMismatch;

  }

  if (r.contains('not signed into')) {

    return CheckInRejectionCategory.rosterOrSignIn;

  }

  return CheckInRejectionCategory.other;

}



StudentOfflineCheckInOutcome outcomeFromRejectionReason(String? reason) {

  switch (categorizeCheckInRejectionReason(reason)) {

    case CheckInRejectionCategory.deviceAlreadyUsed:

      return StudentOfflineCheckInOutcome.deviceBlocked;

    case CheckInRejectionCategory.sessionMismatch:

      return StudentOfflineCheckInOutcome.sessionMismatch;

    case CheckInRejectionCategory.rosterOrSignIn:

    case CheckInRejectionCategory.other:

    case CheckInRejectionCategory.none:

      return StudentOfflineCheckInOutcome.rejectedVerification;

  }

}



String userMessageForCheckInOutcome(

  StudentOfflineCheckInOutcome outcome, {

  String? rejectionReason,

}) {

  final category = categorizeCheckInRejectionReason(rejectionReason);

  if (category == CheckInRejectionCategory.deviceAlreadyUsed) {

    return deviceAlreadyUsedUserMessage;

  }

  if (category == CheckInRejectionCategory.sessionMismatch) {

    return userMessageForSessionMismatch(rejectionReason);

  }

  if (category == CheckInRejectionCategory.rosterOrSignIn) {

    return userMessageForOtherRejection(rejectionReason);

  }



  switch (outcome) {

    case StudentOfflineCheckInOutcome.deviceBlocked:

      return deviceAlreadyUsedUserMessage;

    case StudentOfflineCheckInOutcome.sessionMismatch:

      return userMessageForSessionMismatch(rejectionReason);

    case StudentOfflineCheckInOutcome.duplicate:

      return 'Attendance was already recorded for this session.';

    case StudentOfflineCheckInOutcome.rejectedVerification:

      return userMessageForOtherRejection(rejectionReason);

    case StudentOfflineCheckInOutcome.success:

    case StudentOfflineCheckInOutcome.submittedPendingVerification:

    case StudentOfflineCheckInOutcome.queuedOffline:

      return '';

  }

}



String userMessageForSessionMismatch(String? rejectionReason) {

  final r = rejectionReason?.trim().toLowerCase() ?? '';

  if (r.contains('outside session time') ||

      r.contains('captured outside session time')) {

    return 'Check-in was outside the session time window for this class.';

  }

  if (r.contains('outside class location') ||

      r.contains('outside_geofence') ||

      r.contains('outside geofence')) {

    return 'Check-in was outside the allowed class location for this session.';

  }

  if (r.contains('session does not match') ||

      r.contains('session code not found')) {

    return 'This check-in does not match the active session for that code.';

  }

  if (r.contains('invalid gps')) {

    return 'Check-in location was invalid for this session.';

  }

  return 'Your check-in did not match this session (time, location, or code).';

}



String userMessageForOtherRejection(String? rejectionReason) {

  final r = rejectionReason?.trim().toLowerCase() ?? '';

  if (r.contains('not signed into')) {

    return 'Sign into this class list and choose your course before checking in.';

  }

  if (r.isNotEmpty) {

    return rejectionReason!.trim();

  }

  return 'Check-in was rejected by the server.';

}


