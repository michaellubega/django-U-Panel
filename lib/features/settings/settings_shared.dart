import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/navigation/app_navigator.dart';
import '../../core/theme/app_theme.dart';
import 'delete_account_screen.dart';
import 'privacy_policy_screen.dart';

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

Widget settingsSecurityCard({
  required VoidCallback onChangePassword,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Security',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: AppTheme.textSecondary,
        ),
      ),
      const SizedBox(height: 8),
      Card(
        child: ListTile(
          leading: Icon(Icons.lock_outline_rounded, color: AppTheme.primary),
          title: const Text('Change password'),
          subtitle: const Text('Update the password for this account'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onChangePassword,
        ),
      ),
    ],
  );
}

Widget settingsAboutCard(BuildContext context) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 16),
      Text(
        'About',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: AppTheme.textSecondary,
        ),
      ),
      const SizedBox(height: 8),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: Icon(Icons.school_rounded, color: AppTheme.primary),
              title: const Text('Kampala International University'),
              subtitle: const Text(
                'Class notices and attendance use this app for on-campus sessions.',
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.privacy_tip_outlined, color: AppTheme.primary),
              title: const Text('Privacy Policy'),
              subtitle: const Text('How U-Panel collects and uses your data'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PrivacyPolicyScreen(),
                  ),
                );
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.person_remove_outlined, color: AppTheme.primary),
              title: const Text('Delete account'),
              subtitle: const Text('Request removal of your U-Panel account'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DeleteAccountScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    ],
  );
}
