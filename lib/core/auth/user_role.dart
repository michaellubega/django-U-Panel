/// Firebase-backed app role (not user-selectable).
enum UserRole {
  student,
  lecturer,
  /// QA staff: full operational access via [admins] + `isAdmin`, not labelled "Administrator".
  qaStaff,
  /// Full administrator (email-based or explicitly granted).
  admin,
  /// KIU administrator: campus check-in/out required; lecturer attendance access.
  kiuAdmin,
  /// Vice-Chancellor — read-only quality overview.
  vc,
  /// Deputy Vice-Chancellor — same overview as [vc].
  dvc,
  /// Director of Quality Assurance — read-only reports hub.
  dqa,
  /// Dean — faculty-level read-only overview.
  dean,
  /// Head of Department — department-level read-only overview.
  hod,
}

extension UserRoleX on UserRole {
  String get label {
    switch (this) {
      case UserRole.student:
        return 'Student';
      case UserRole.lecturer:
        return 'Lecturer';
      case UserRole.qaStaff:
        return 'QA officer';
      case UserRole.admin:
        return 'Administrator';
      case UserRole.kiuAdmin:
        return 'KIU ADMIN';
      case UserRole.vc:
        return 'Vice-Chancellor';
      case UserRole.dvc:
        return 'Deputy Vice-Chancellor';
      case UserRole.dqa:
        return 'Director of QA';
      case UserRole.dean:
        return 'Dean';
      case UserRole.hod:
        return 'Head of Department';
    }
  }

  String get apiValue {
    switch (this) {
      case UserRole.student:
        return 'student';
      case UserRole.lecturer:
        return 'lecturer';
      case UserRole.qaStaff:
        return 'qa_staff';
      case UserRole.admin:
        return 'administrator';
      case UserRole.kiuAdmin:
        return 'kiu_admin';
      case UserRole.vc:
        return 'vc';
      case UserRole.dvc:
        return 'dvc';
      case UserRole.dqa:
        return 'dqa';
      case UserRole.dean:
        return 'dean';
      case UserRole.hod:
        return 'hod';
    }
  }

  /// Dashboard, attendance QA tools, reports, staff hub (same nav as [admin]).
  bool get hasStaffOperationalAccess =>
      this == UserRole.qaStaff || this == UserRole.admin;

  bool get hasLecturerAttendanceAccess =>
      this == UserRole.lecturer || this == UserRole.kiuAdmin;

  /// Read-only QAAT-style dashboards. Capture / session writes stay off.
  bool get hasOversightReadAccess {
    switch (this) {
      case UserRole.vc:
      case UserRole.dvc:
      case UserRole.dqa:
      case UserRole.dean:
      case UserRole.hod:
        return true;
      case UserRole.student:
      case UserRole.lecturer:
      case UserRole.qaStaff:
      case UserRole.admin:
      case UserRole.kiuAdmin:
        return false;
    }
  }

  bool get usesQaatOversightHome =>
      hasOversightReadAccess || this == UserRole.admin || this == UserRole.qaStaff;

  static UserRole? fromApi(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'student':
        return UserRole.student;
      case 'lecturer':
      case 'staff':
        return UserRole.lecturer;
      case 'qa_staff':
        return UserRole.qaStaff;
      case 'administrator':
        return UserRole.admin;
      case 'kiu_admin':
      case 'kiu_administrator':
        return UserRole.kiuAdmin;
      case 'vc':
        return UserRole.vc;
      case 'dvc':
        return UserRole.dvc;
      case 'dqa':
        return UserRole.dqa;
      case 'dean':
        return UserRole.dean;
      case 'hod':
        return UserRole.hod;
      default:
        return null;
    }
  }
}

/// Which profile fields the signed-in user may edit themselves.
enum SelfServiceProfileKind {
  student,
  administrator,
  lecturer,
}
