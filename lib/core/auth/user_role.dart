/// Firebase-backed app role (not user-selectable).
enum UserRole {
  student,
  lecturer,
  /// QA staff: full operational access via [admins] + `isAdmin`, not labelled "Administrator".
  qaStaff,
  /// Full administrator (email-based or explicitly granted).
  admin,
}

extension UserRoleX on UserRole {
  String get label {
    switch (this) {
      case UserRole.student:
        return 'Student';
      case UserRole.lecturer:
        return 'Lecturer';
      case UserRole.qaStaff:
        return 'QA staff';
      case UserRole.admin:
        return 'Administrator';
    }
  }

  /// Dashboard, attendance QA tools, reports, staff hub (same nav as [admin]).
  bool get hasStaffOperationalAccess =>
      this == UserRole.qaStaff || this == UserRole.admin;
}
