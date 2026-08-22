import 'package:flutter/material.dart';

/// Legacy client-side role toggle (unused). Use [AuthRepository.resolvedRole] instead.
@Deprecated('Use AuthRepository.resolvedRole from lib/core/auth/user_role.dart')
enum AppRole {
  student,
  qaStaff,
}

extension AppRoleX on AppRole {
  String get label {
    switch (this) {
      case AppRole.student:
        return 'Student';
      case AppRole.qaStaff:
        return 'QA-Staff';
    }
  }

  String get description {
    switch (this) {
      case AppRole.student:
        return 'Sign in to attendance and view notices';
      case AppRole.qaStaff:
        return 'Manage lists, approvals, reports';
    }
  }

  IconData get icon {
    switch (this) {
      case AppRole.student:
        return Icons.school_rounded;
      case AppRole.qaStaff:
        return Icons.admin_panel_settings_rounded;
    }
  }
}

class RoleScope extends InheritedWidget {
  const RoleScope({
    super.key,
    required this.role,
    required super.child,
    this.onRoleChanged,
  });

  final AppRole role;
  final void Function(AppRole)? onRoleChanged;

  static RoleScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<RoleScope>();
    assert(scope != null, 'RoleScope not found. Wrap app with RoleScope.');
    return scope!;
  }

  @override
  bool updateShouldNotify(RoleScope oldWidget) => role != oldWidget.role;
}
