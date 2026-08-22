/// Canonical REST **resource paths** for the Django backend.
///
/// Maps former Firestore collection names to API routes (see `backend/` apps).
abstract final class ApiCollections {
  static const attendanceLists = 'attendance/lists';
  static const attendanceSessions = 'attendance/sessions';
  static const attendanceRecords = 'attendance/records';
  static const checkInAttempts = 'attendance/check-in-attempts';
  static const students = 'attendance/students';
  static const signIns = 'attendance/sign-ins';
  static const notices = 'notices';
  static const appUsers = 'accounts/users';
  static const admins = 'accounts/admins';
  static const adminsLegacy = 'accounts/admins';
  static const lecturers = 'accounts/lecturers';
  static const staffNumbers = 'accounts/staff-numbers';
  static const studentRegistrations = 'accounts/student-registrations';
  static const meta = 'attendance/health';
  static const lecturerStaffCounterDocId = 'lecturer_staff_counter';
  static const connectivityPingDocId = 'connectivity';
  static const campusGeofenceDocId = 'campus/geofence';
  static const adminCampusPresence = 'campus/presence';
}
