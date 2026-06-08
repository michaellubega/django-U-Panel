import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/auth/staff_auth_email.dart';
import '../../core/theme/app_theme.dart';
import 'change_password_screen.dart';
import 'update_profile_screen.dart';
import 'settings_shared.dart';
import '../../core/navigation/app_section.dart';
import '../../core/navigation/screen_refresh.dart';

/// Profile and security for lecturer (KIU-####) accounts.
class LecturerSettingsScreen extends StatefulWidget {
  const LecturerSettingsScreen({
    super.key,
    this.shellSection = AppSection.settings,
  });

  final AppSection shellSection;

  @override
  State<LecturerSettingsScreen> createState() => _LecturerSettingsScreenState();
}

class _LecturerSettingsScreenState extends State<LecturerSettingsScreen> {
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthRepository.instance,
      builder: (context, _) {
        final auth = AuthRepository.instance;
        final email = _profile?['email'] ?? auth.currentEmail;
        final visibleEmail = StaffAuthEmail.syntheticEmailToStaffNumber(
                  email ?? '',
                ) !=
                null
            ? '—'
            : email;
        final isKiuAdmin = auth.isKiuAdmin;
        final fullName =
            (_profile?['fullName'] ?? auth.currentFullName)?.trim();
        final displayName = (fullName != null && fullName.isNotEmpty)
            ? fullName
            : (isKiuAdmin ? 'KIU Administrator' : 'Lecturer');
        final staffNumber = auth.currentStaffNumber?.trim();
        final accountLabel = isKiuAdmin ? 'KIU ADMIN' : 'Lecturer account';
        final profileSubtitle =
            isKiuAdmin ? 'Your KIU admin account' : 'Your lecturer account';

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
                profileSubtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
              ),
              const SizedBox(height: 22),
              if (!auth.lecturerCheckDone)
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
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              AppTheme.primary.withValues(alpha: 0.85),
                              AppTheme.primary,
                            ],
                          ),
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
                                  settingsInitialsFrom(fullName, visibleEmail),
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                    const SizedBox(height: 6),
                                    Text(
                                      visibleEmail ?? '—',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: Colors.white
                                                .withValues(alpha: 0.92),
                                          ),
                                    ),
                                    if (staffNumber != null &&
                                        staffNumber.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        staffNumber,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelLarge
                                            ?.copyWith(
                                              color: Colors.white
                                                  .withValues(alpha: 0.85),
                                            ),
                                      ),
                                    ],
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.person_rounded,
                                          size: 18,
                                          color: Colors.white
                                              .withValues(alpha: 0.9),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          accountLabel,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium
                                              ?.copyWith(
                                                color: Colors.white
                                                    .withValues(alpha: 0.88),
                                                fontWeight: FontWeight.w600,
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
                      settingsSignOutButton(
                        context: context,
                        auth: auth,
                        email: email,
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              settingsSecurityCard(
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
