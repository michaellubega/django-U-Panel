import 'package:flutter/material.dart';

import '../../core/navigation/app_section.dart';
import '../../core/theme/app_theme.dart';
import '../campus_presence/admin_campus_presence_card.dart';
import '../campus_presence/campus_check_in_screen.dart';
import '../campus_presence/kiu_admin_check_in_records_screen.dart';
import '../dashboard/dashboard_shared_widgets.dart';

/// Home for KIU administrators — campus check-in first, then attendance shortcuts.
class KiuAdminDashboardScreen extends StatelessWidget {
  const KiuAdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          'KIU administrator',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Campus check-in is required every working day. You can create and '
          'run attendance lists from the Attendance tab.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppTheme.textSecondary,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 20),
        const AdminCampusPresenceCard(),
        const SizedBox(height: 12),
        DashboardStatTile(
          label: 'Check in / out now',
          value: 'Open',
          icon: Icons.place_rounded,
          color: AppTheme.primary,
          highlight: true,
          onTap: () {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const CampusCheckInScreen(),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        DashboardStatTile(
          label: 'My check-in records',
          value: 'History',
          icon: Icons.history_rounded,
          color: AppTheme.secondary,
          onTap: () {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const KiuAdminCheckInRecordsScreen(),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        DashboardQuickAction(
          icon: Icons.fact_check_rounded,
          label: 'Attendance lists',
          subtitle: 'Create sessions and take roll like a lecturer',
          onTap: () => DashboardShellNav.go(context, AppSection.attendance),
        ),
        const SizedBox(height: 8),
        DashboardQuickAction(
          icon: Icons.notifications_active_rounded,
          label: 'Notices',
          onTap: () => DashboardShellNav.go(context, AppSection.notices),
        ),
      ],
    );
  }
}
