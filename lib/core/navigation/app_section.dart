import 'package:flutter/material.dart';

enum AppSection {
  dashboard,
  attendance,
  notices,
  reports,
  settings,
}

extension AppSectionX on AppSection {
  String get label {
    switch (this) {
      case AppSection.dashboard:
        return 'Dashboard';
      case AppSection.attendance:
        return 'Attendance';
      case AppSection.notices:
        return 'Notices';
      case AppSection.reports:
        return 'Reports';
      case AppSection.settings:
        return 'Settings';
    }
  }

  IconData get icon {
    switch (this) {
      case AppSection.dashboard:
        return Icons.dashboard_rounded;
      case AppSection.attendance:
        return Icons.people_alt_rounded;
      case AppSection.notices:
        return Icons.campaign_rounded;
      case AppSection.reports:
        return Icons.analytics_rounded;
      case AppSection.settings:
        return Icons.settings_rounded;
    }
  }
}
