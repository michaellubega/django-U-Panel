import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/navigation/app_section.dart';
import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';
import '../campus_presence/kiu_admin_check_in_records_screen.dart';
import '../campus_presence/kiu_admin_ui.dart';
import 'change_password_screen.dart';
import 'settings_shared.dart';
import 'update_profile_screen.dart';

/// Profile and campus tools for KIU administrator accounts (not QA staff).
class KiuAdminSettingsScreen extends StatefulWidget {
  const KiuAdminSettingsScreen({
    super.key,
    this.shellSection = AppSection.settings,
  });

  final AppSection shellSection;

  @override
  State<KiuAdminSettingsScreen> createState() => _KiuAdminSettingsScreenState();
}

class _KiuAdminSettingsScreenState extends State<KiuAdminSettingsScreen> {
  Map<String, String>? _profile;

  @override
  void initState() {
    super.initState();
    AuthRepository.instance.addListener(_onAuth);
    unawaited(_loadProfile());
  }

  @override
  void dispose() {
    AuthRepository.instance.removeListener(_onAuth);
    super.dispose();
  }

  void _onAuth() {
    unawaited(_loadProfile());
  }

  Future<void> _loadProfile() async {
    final p = await AuthRepository.instance.profileForCurrentUser();
    if (mounted) setState(() => _profile = p);
  }

  void _openRecords() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const KiuAdminCheckInRecordsScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthRepository.instance,
      builder: (context, _) {
        final auth = AuthRepository.instance;
        final email = _profile?['email'] ?? auth.currentEmail;
        final fullName =
            (_profile?['fullName'] ?? auth.currentFullName)?.trim();
        final displayName = (fullName != null && fullName.isNotEmpty)
            ? fullName
            : 'KIU administrator';
        final jobTitle = (_profile?[AuthRepository.kiuAdminJobTitleField] ??
                auth.currentKiuAdminJobTitle)
            ?.trim();
        final staffNumber = auth.currentStaffNumber?.trim();
        final reg = auth.currentRegistrationNumber?.trim();

        return ScreenRefreshRegistrar(
          section: widget.shellSection,
          onRefresh: _loadProfile,
          child: PullToRefreshBody(
            onRefresh: _loadProfile,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Profile',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Campus check-in account',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                ),
                const SizedBox(height: 22),
                if (!auth.adminCheckDone)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  )
                else
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DecoratedBox(
                          decoration: const BoxDecoration(
                            gradient: KiuAdminUi.gradient,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 40,
                                  backgroundColor:
                                      Colors.white.withValues(alpha: 0.92),
                                  foregroundColor: AppTheme.primary,
                                  child: Text(
                                    settingsInitialsFrom(fullName, email),
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          color: AppTheme.primary,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        displayName,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge
                                            ?.copyWith(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                      if (jobTitle != null &&
                                          jobTitle.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          jobTitle,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                color: Colors.white
                                                    .withValues(alpha: 0.9),
                                              ),
                                        ),
                                      ],
                                      const SizedBox(height: 8),
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.admin_panel_settings_rounded,
                                            size: 18,
                                            color: Colors.white
                                                .withValues(alpha: 0.9),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            'KIU ADMIN',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelMedium
                                                ?.copyWith(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.88),
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: 0.4,
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
                        ),
                        if (staffNumber != null && staffNumber.isNotEmpty ||
                            (reg != null && reg.isNotEmpty) ||
                            (email != null && email.trim().isNotEmpty))
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (staffNumber != null &&
                                    staffNumber.isNotEmpty)
                                  settingsDetailChip(
                                    icon: Icons.badge_outlined,
                                    label: 'Staff number',
                                    value: staffNumber,
                                  ),
                                if (reg != null && reg.isNotEmpty) ...[
                                  if (staffNumber != null &&
                                      staffNumber.isNotEmpty)
                                    const SizedBox(height: 10),
                                  settingsDetailChip(
                                    icon: Icons.numbers_rounded,
                                    label: 'Registration number',
                                    value: reg,
                                  ),
                                ],
                                if (email != null && email.trim().isNotEmpty)
                                  ...[
                                    if ((staffNumber != null &&
                                            staffNumber.isNotEmpty) ||
                                        (reg != null && reg.isNotEmpty))
                                      const SizedBox(height: 10),
                                    settingsDetailChip(
                                      icon: Icons.mail_outline_rounded,
                                      label: 'Email',
                                      value: email.trim(),
                                    ),
                                  ],
                              ],
                            ),
                          ),
                        settingsSignOutButton(
                          context: context,
                          auth: auth,
                          email: email,
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 18),
                KiuAdminSurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const KiuAdminSectionTitle('Campus'),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _openRecords,
                        icon: const Icon(Icons.history_rounded, size: 20),
                        label: const Text('Check-in records'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const KiuAdminInfoBanner(
                        message:
                            'Use the Home tab to check in and out at campus each working day.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                settingsSecurityCard(
                  context: context,
                  onUpdateProfile: () async {
                    final updated = await Navigator.of(context).push<bool>(
                      MaterialPageRoute<bool>(
                        builder: (_) => const UpdateProfileScreen(),
                      ),
                    );
                    if (updated == true && mounted) {
                      await _loadProfile();
                    }
                  },
                  onChangePassword: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ChangePasswordScreen(),
                      ),
                    );
                  },
                ),
                settingsAboutCard(context),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }
}
