/// Canonical Firestore **collection names** for the `upanel` database
/// ([uPanelFirestore]). Use these instead of string literals so renames stay safe.
///
/// ## How this maps to a “textbook” school schema
///
/// U-Panel keeps existing collection ids for backward compatibility. Conceptually:
///
/// | Typical name | This app | Id / key pattern |
/// |--------------|----------|-------------------|
/// | `users` | `app_users` + Firebase Auth | `app_users/{authUid}` (see `AuthRepository`) |
/// | `classes` | `attendance_lists` | One doc per class list |
/// | `sessions` | `attendance_sessions` | `listId` links session → list |
/// | `attendance` | `attendance_records` | Doc id `{sessionId}_{studentId}`. **Server-only writes** (Cloud Functions after reconciling [checkInAttempts]). |
/// | Enrolments / course | `sign_ins` | `listId` + `studentId` + chosen `course` |
/// | People directory | `students` | Global student rows (registration #, etc.) |
/// | Broadcasts | `notices` | Optional `kind`, `sessionCode`, class targeting |
///
/// ## Check-in attempts (device → server)
///
/// Devices upload GPS/code evidence to [checkInAttempts]. Claims with
/// `awaitingSession: true` wait up to 7 days for a matching lecturer session.
/// Cloud Functions validate and write official rows to [attendanceRecords].
abstract final class FirestoreCollections {
  static const attendanceLists = 'attendance_lists';
  static const attendanceSessions = 'attendance_sessions';
  static const attendanceRecords = 'attendance_records';

  /// Student check-in evidence; doc id `{sessionId}_{studentId}`.
  static const checkInAttempts = 'check_in_attempts';
  static const students = 'students';
  static const signIns = 'sign_ins';
  static const notices = 'notices';
  static const appUsers = 'app_users';
  static const admins = 'admins';

  /// Legacy collection name (some early data used `admin` instead of [admins]).
  static const adminsLegacy = 'admin';
  static const lecturers = 'lecturers';
  static const staffNumbers = 'staff_numbers';

  /// One doc per student reg (`YYYY-MM-#####`) → single Auth uid + email.
  static const studentRegistrations = 'student_registrations';
  static const meta = 'meta';

  /// Doc id under [meta] for atomic staff id sequence (see AuthRepository).
  static const lecturerStaffCounterDocId = 'lecturer_staff_counter';

  /// Public ping doc for Firestore reachability checks before sign-in.
  static const connectivityPingDocId = 'connectivity';

  /// Center + radius for admin campus arrival / departure check-in.
  static const campusGeofenceDocId = 'campus_geofence';

  /// Admin / QA staff campus arrival and departure events.
  static const adminCampusPresence = 'admin_campus_presence';
}
