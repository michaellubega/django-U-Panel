import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/navigation/app_navigator.dart';
import '../../core/theme/app_theme.dart';
import 'delete_account_screen.dart';
import 'privacy_policy_screen.dart';
import '../portal/student_portal_screen.dart';

String settingsInitialsFrom(String? fullName, String? email) {
  final name = fullName?.trim();
  if (name != null && name.isNotEmpty) {
    final parts = name.split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.substring(0, 1).toUpperCase();
  }
  final em = email?.trim();
  if (em != null && em.isNotEmpty) {
    return em.substring(0, 1).toUpperCase();
  }
  return '?';
}

bool settingsIsSignOutBlockedOffline() =>
    AppConnectivity.instance.initialized &&
    !AppConnectivity.instance.isOnline;

/// Sign out when online; snackbar via root navigator (safe after shell dispose).
Future<void> settingsTrySignOut(
  BuildContext context,
  AuthRepository auth,
) async {
  if (settingsIsSignOutBlockedOffline()) {
    showRootSnackBar(AuthRepository.signOutRequiresInternetMessage);
    return;
  }

  final err = await auth.logout();
  if (err != null) {
    showRootSnackBar(err);
  }
}

Widget settingsSignOutButton({
  required BuildContext context,
  required AuthRepository auth,
  required String? email,
  EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(20, 0, 20, 20),
}) {
  return ListenableBuilder(
    listenable: AppConnectivity.instance,
    builder: (context, _) {
      final offline = settingsIsSignOutBlockedOffline();
      final enabled = email != null;

      return Padding(
        padding: padding,
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: enabled ? () => settingsTrySignOut(context, auth) : null,
            icon: Icon(
              offline ? Icons.wifi_off_rounded : Icons.logout_rounded,
              size: 20,
            ),
            label: Text(
              offline ? 'Sign out (needs internet)' : 'Sign out',
            ),
            style: enabled && offline
                ? OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.textSecondary,
                  )
                : null,
          ),
        ),
      );
    },
  );
}

Widget settingsSectionHeader(BuildContext context, String title) {
  return Text(
    title,
    style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          color: AppTheme.textSecondary,
        ),
  );
}

Widget settingsActionTile({
  required IconData icon,
  required String title,
  required String subtitle,
  VoidCallback? onTap,
  Color? iconColor,
  bool showDivider = false,
}) {
  final color = iconColor ?? AppTheme.primary;
  return Column(
    children: [
      if (showDivider) const Divider(height: 1),
      ListTile(
        leading: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(subtitle),
        trailing: onTap == null
            ? null
            : Icon(
                Icons.chevron_right_rounded,
                color: AppTheme.textSecondary.withValues(alpha: 0.7),
              ),
        onTap: onTap,
      ),
    ],
  );
}

Widget settingsProfileHero({
  required BuildContext context,
  required String displayName,
  required String? email,
  required String accountLabel,
  required String initials,
  required Gradient gradient,
  IconData accountIcon = Icons.person_rounded,
  String? secondaryLine,
  String? badgeLabel,
}) {
  final theme = Theme.of(context);
  return DecoratedBox(
    decoration: BoxDecoration(gradient: gradient),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 40,
            backgroundColor: Colors.white.withValues(alpha: 0.92),
            foregroundColor: AppTheme.primary,
            child: Text(
              initials,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: const Color(0xFF0F4D2E),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (badgeLabel != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.28),
                      ),
                    ),
                    child: Text(
                      badgeLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.95),
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Text(
                  displayName,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  email?.trim().isNotEmpty == true ? email!.trim() : '—',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                ),
                if (secondaryLine != null && secondaryLine.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    secondaryLine,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      accountIcon,
                      size: 18,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        accountLabel,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.88),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

Widget settingsDetailChip({
  required IconData icon,
  required String label,
  required String value,
}) {
  return Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppTheme.softGrey.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppTheme.softGrey),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: AppTheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

Widget settingsSecurityCard({
  required BuildContext context,
  required VoidCallback onChangePassword,
  VoidCallback? onUpdateProfile,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (onUpdateProfile != null) ...[
        settingsSectionHeader(context, 'Account'),
        const SizedBox(height: 10),
        Card(
          clipBehavior: Clip.antiAlias,
          child: settingsActionTile(
            icon: Icons.person_outline_rounded,
            title: 'Update profile',
            subtitle: 'Change your name and registration number',
            onTap: onUpdateProfile,
          ),
        ),
        const SizedBox(height: 18),
      ],
      settingsSectionHeader(context, 'Security'),
      const SizedBox(height: 10),
      Card(
        clipBehavior: Clip.antiAlias,
        child: settingsActionTile(
          icon: Icons.lock_outline_rounded,
          title: 'Change password',
          subtitle: 'Update the password for this account',
          onTap: onChangePassword,
        ),
      ),
    ],
  );
}

Widget settingsStudentPortalCard(BuildContext context) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      settingsSectionHeader(context, 'KIU'),
      const SizedBox(height: 10),
      Card(
        clipBehavior: Clip.antiAlias,
        child: settingsActionTile(
          icon: Icons.language_rounded,
          title: 'Portal',
          subtitle:
              'Open the KIU student portal — your saved passwords can autofill',
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const StudentPortalScreen(),
              ),
            );
          },
        ),
      ),
    ],
  );
}

Widget settingsAboutCard(BuildContext context) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 18),
      settingsSectionHeader(context, 'About'),
      const SizedBox(height: 10),
      Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            settingsActionTile(
              icon: Icons.school_rounded,
              title: 'Kampala International University',
              subtitle:
                  'Class notices and attendance use this app for on-campus sessions.',
              onTap: null,
            ),
            settingsActionTile(
              icon: Icons.privacy_tip_outlined,
              title: 'Privacy Policy',
              subtitle: 'How U-Panel collects and uses your data',
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PrivacyPolicyScreen(),
                  ),
                );
              },
              showDivider: true,
            ),
            settingsActionTile(
              icon: Icons.person_remove_outlined,
              title: 'Delete account',
              subtitle: 'Request removal of your U-Panel account',
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DeleteAccountScreen(),
                  ),
                );
              },
              showDivider: true,
            ),
          ],
        ),
      ),
    ],
  );
}
