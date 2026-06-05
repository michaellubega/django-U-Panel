import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/admin_gate.dart';
import 'lecturers_list_screen.dart';
import 'qa_staff_list_screen.dart';
import 'register_administrator_screen.dart';
import 'register_staff_screen.dart';

/// Admin hub for lecturer/QA staff accounts (Dashboard, drawer, or sidebar).
class StaffAdminHubScreen extends StatelessWidget {
  const StaffAdminHubScreen({super.key});

  /// Below this width, use a single centered column (phones / narrow panes).
  static const double _splitBreakpoint = 700;

  /// Cap width so lines do not sprawl on ultra-wide monitors.
  static const double _maxPanelWidth = 1040;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AdminGate(
      title: 'Staff & accounts',
      child: Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        title: const Text('Staff & accounts'),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final split = w >= _splitBreakpoint;
          const hPad = 24.0;
          final innerMax = (w - hPad * 2).clamp(0.0, _maxPanelWidth);

          return Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(hPad, 20, hPad, 28),
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: innerMax),
                  child: split
                      ? _DesktopSplitLayout(textTheme: textTheme)
                      : _CompactColumnLayout(textTheme: textTheme),
                ),
              ),
            ),
          );
        },
      ),
    ),
    );
  }
}

/// Side-by-side: summary + register | browse directory panel.
class _DesktopSplitLayout extends StatelessWidget {
  const _DesktopSplitLayout({required this.textTheme});

  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 11,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HubIntro(textTheme: textTheme, dense: true),
              const SizedBox(height: 20),
              _RegisterHeroCard(
                onTap: () => _pushRegister(context),
                compact: false,
              ),
              const _GrantAdministratorSection(gapBefore: 20),
            ],
          ),
        ),
        const SizedBox(width: 28),
        Expanded(
          flex: 10,
          child: _BrowsePanelCard(
            textTheme: textTheme,
            onLecturers: () => _pushLecturers(context),
            onQaStaff: () => _pushQaStaff(context),
          ),
        ),
      ],
    );
  }

  void _pushRegister(BuildContext context) {
    Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const RegisterStaffScreen(),
      ),
    );
  }

  void _pushLecturers(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const LecturersListScreen(),
      ),
    );
  }

  void _pushQaStaff(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const QaStaffListScreen(),
      ),
    );
  }
}

/// Stacked layout for narrow viewports.
class _CompactColumnLayout extends StatelessWidget {
  const _CompactColumnLayout({required this.textTheme});

  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    final wideTiles = MediaQuery.sizeOf(context).width >= 600;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HubIntro(textTheme: textTheme, dense: false),
        const SizedBox(height: 16),
        Text(
          'Create',
          style: textTheme.labelLarge?.copyWith(
            color: AppTheme.textSecondary,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 10),
        _RegisterHeroCard(
          onTap: () {
            Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                builder: (_) => const RegisterStaffScreen(),
              ),
            );
          },
          compact: true,
        ),
        const _GrantAdministratorSection(gapBefore: 12),
        const SizedBox(height: 28),
        Text(
          'Browse',
          style: textTheme.labelLarge?.copyWith(
            color: AppTheme.textSecondary,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 10),
        if (wideTiles)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _DirectoryTile(
                    icon: Icons.school_rounded,
                    title: 'Lecturers',
                    subtitle: 'KIU accounts, sign-in with staff ID',
                    tint: AppTheme.primary,
                    onTap: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const LecturersListScreen(),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _DirectoryTile(
                    icon: Icons.verified_user_rounded,
                    title: 'QA staff',
                    subtitle: 'Admins and full access roles',
                    tint: AppTheme.secondary,
                    onTap: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const QaStaffListScreen(),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          )
        else ...[
          _DirectoryTile(
            icon: Icons.school_rounded,
            title: 'Lecturers',
            subtitle: 'KIU accounts, sign-in with staff ID',
            tint: AppTheme.primary,
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const LecturersListScreen(),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          _DirectoryTile(
            icon: Icons.verified_user_rounded,
            title: 'QA staff',
            subtitle: 'Admins and full access roles',
            tint: AppTheme.secondary,
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const QaStaffListScreen(),
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

/// Right column on desktop: one card, list-style rows.
class _BrowsePanelCard extends StatelessWidget {
  const _BrowsePanelCard({
    required this.textTheme,
    required this.onLecturers,
    required this.onQaStaff,
  });

  final TextTheme textTheme;
  final VoidCallback onLecturers;
  final VoidCallback onQaStaff;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: AppTheme.cardElevation,
      shadowColor: AppTheme.primary.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        side: const BorderSide(color: AppTheme.softGrey),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Text(
              'Browse',
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
            child: Text(
              'Open directory lists in full screen.',
              style: textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
                height: 1.35,
              ),
            ),
          ),
          const Divider(height: 1),
          _PanelLinkTile(
            icon: Icons.school_rounded,
            iconTint: AppTheme.primary,
            title: 'Lecturers',
            subtitle: 'KIU-#### accounts and profile rows',
            onTap: onLecturers,
          ),
          const Divider(height: 1),
          _PanelLinkTile(
            icon: Icons.verified_user_rounded,
            iconTint: AppTheme.secondary,
            title: 'QA staff',
            subtitle: 'Admin accounts (isAdmin)',
            onTap: onQaStaff,
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _PanelLinkTile extends StatelessWidget {
  const _PanelLinkTile({
    required this.icon,
    required this.iconTint,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color iconTint;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: iconTint.withValues(alpha: 0.06),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: iconTint.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconTint, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: AppTheme.textSecondary.withValues(alpha: 0.65),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full administrators only — same hero + screen pattern as [RegisterStaffScreen].
class _GrantAdministratorSection extends StatelessWidget {
  const _GrantAdministratorSection({required this.gapBefore});

  final double gapBefore;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthRepository.instance,
      builder: (context, _) {
        final auth = AuthRepository.instance;
        if (!auth.adminCheckDone || !auth.isFullAdministrator) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: gapBefore),
            _GrantAdministratorHeroCard(
              onTap: () {
                Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) => const RegisterAdministratorScreen(),
                  ),
                );
              },
              compact: MediaQuery.sizeOf(context).width <
                  StaffAdminHubScreen._splitBreakpoint,
            ),
          ],
        );
      },
    );
  }
}

class _GrantAdministratorHeroCard extends StatelessWidget {
  const _GrantAdministratorHeroCard({
    required this.onTap,
    required this.compact,
  });

  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: AppTheme.secondary,
      elevation: 2,
      shadowColor: AppTheme.secondary.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 20 : 24,
            vertical: compact ? 20 : 22,
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.admin_panel_settings_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  'Grant administrator access',
                  style: textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HubIntro extends StatelessWidget {
  const _HubIntro({
    required this.textTheme,
    required this.dense,
  });

  final TextTheme textTheme;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        dense ? 20 : 18,
        dense ? 18 : 20,
        dense ? 20 : 18,
        dense ? 18 : 22,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.primary.withValues(alpha: 0.12),
            AppTheme.accentLight.withValues(alpha: 0.32),
          ],
        ),
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _IntroIconBadge(),
          SizedBox(width: dense ? 12 : 16),
          Expanded(
            child: Text(
              dense ? 'Staff & attendance' : 'People who run attendance',
              style: (dense ? textTheme.titleLarge : textTheme.titleMedium)
                  ?.copyWith(
                fontWeight: dense ? FontWeight.w800 : FontWeight.w700,
                color: AppTheme.textPrimary,
                letterSpacing: dense ? -0.2 : null,
                height: dense ? null : 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IntroIconBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.07),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: const Icon(
        Icons.groups_rounded,
        size: 28,
        color: AppTheme.primary,
      ),
    );
  }
}

class _RegisterHeroCard extends StatelessWidget {
  const _RegisterHeroCard({
    required this.onTap,
    required this.compact,
  });

  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: AppTheme.primary,
      elevation: 2,
      shadowColor: AppTheme.primary.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 20 : 24,
            vertical: compact ? 20 : 22,
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.person_add_alt_1_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  'Register staff',
                  style: textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DirectoryTile extends StatelessWidget {
  const _DirectoryTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tint,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: AppTheme.background,
      elevation: AppTheme.cardElevation,
      shadowColor: tint.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: tint, size: 22),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: AppTheme.textSecondary.withValues(alpha: 0.7),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                title,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
