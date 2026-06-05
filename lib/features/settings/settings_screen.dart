import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/auth/staff_auth_email.dart';
import '../../core/auth/user_role.dart';
import 'change_password_screen.dart';
import '../../core/theme/app_theme.dart';
import 'settings_shared.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/attendance_list_title.dart';
import '../attendance/models/attendance_models.dart';
import 'lecturer_settings_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  static const Duration _autoRefreshInterval = Duration(seconds: 30);
  Timer? _autoRefreshTimer;

  Map<String, String>? _profile;
  bool _attendanceStatsLoaded = false;
  List<AttendanceListRollStats> _attendanceByList = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AuthRepository.instance.addListener(_onAuth);
    _loadProfile();
    _loadAttendanceStats();
    _autoRefreshTimer =
        Timer.periodic(_autoRefreshInterval, (_) => _refreshProfileAndStats());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoRefreshTimer?.cancel();
    AuthRepository.instance.removeListener(_onAuth);
    super.dispose();
  }

  void _onAuth() {
    if (!AuthRepository.instance.isLoggedIn) {
      if (mounted) setState(() => _profile = null);
      return;
    }
    _refreshProfileAndStats();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshProfileAndStats();
    }
  }

  Future<void> _refreshProfileAndStats() async {
    try {
      await Future.wait([
        _loadProfile(),
        _loadAttendanceStats(),
      ]);
    } catch (_) {
      // Keep profile usable if background refresh fails.
    }
  }

  Future<void> _loadProfile() async {
    final p = await AuthRepository.instance.profileForCurrentUser();
    if (mounted) setState(() => _profile = p);
  }

  Future<void> _loadAttendanceStats() async {
    final auth = AuthRepository.instance;
    if (auth.adminCheckDone && auth.isAdmin) {
      if (mounted) {
        setState(() {
          _attendanceStatsLoaded = true;
          _attendanceByList = const [];
        });
      }
      return;
    }
    if (auth.lecturerCheckDone && auth.isLecturer && !auth.isAdmin) {
      if (mounted) {
        setState(() {
          _attendanceStatsLoaded = true;
          _attendanceByList = const [];
        });
      }
      return;
    }
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg == null || reg.isEmpty) {
      if (mounted) {
        setState(() {
          _attendanceStatsLoaded = true;
          _attendanceByList = const [];
        });
      }
      return;
    }

    void applyRollStats() {
      if (!mounted) return;
      setState(() {
        _attendanceStatsLoaded = true;
        _attendanceByList =
            AttendanceStore.rollStatsPerListForRegistrationNormalized(reg);
      });
    }

    // If attendance was already loaded elsewhere (e.g. Attendance tab, app
    // shell), show the percentage immediately instead of waiting on Firestore.
    if (AttendanceRepository.instance.isLoaded) {
      applyRollStats();
    }

    // Avoid force: true here — that always re-downloads five large collections
    // and was the main reason the profile % felt slow. Non-forced load skips
    // the network when data is already in memory (see [loadAll]).
    await AttendanceRepository.instance.loadAll(
      force: false,
      scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
    );
    applyRollStats();
  }

  /// High attendance → green; low → red (HSV sweep red 0° … green 120°).
  static Color _attendanceQualityColor(int percent) {
    final t = percent.clamp(0, 100) / 100.0;
    return HSVColor.fromAHSV(1.0, t * 120.0, 0.82, 0.94).toColor();
  }

  static String _initialsFrom(String? fullName, String? email) {
    String firstChar(String s) =>
        s.isEmpty ? '' : String.fromCharCode(s.runes.first).toUpperCase();

    final n = fullName?.trim();
    if (n != null && n.isNotEmpty) {
      final parts = n.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
      if (parts.length >= 2) {
        return '${firstChar(parts.first)}${firstChar(parts.last)}';
      }
      final one = parts.first;
      if (one.runes.length >= 2) {
        final it = one.runes.iterator;
        it.moveNext();
        final a = String.fromCharCode(it.current);
        it.moveNext();
        final b = String.fromCharCode(it.current);
        return '$a$b'.toUpperCase();
      }
      return firstChar(one);
    }
    final e = email?.trim();
    if (e != null && e.isNotEmpty) {
      if (e.length >= 2) return e.substring(0, 2).toUpperCase();
      return e.toUpperCase();
    }
    return '?';
  }

  Widget _buildPerListAttendanceTile(
    BuildContext context,
    AttendanceListRollStats row,
  ) {
    final theme = Theme.of(context);
    final stats = row.stats;
    final hasSessions = stats.total > 0;
    final pct = stats.percentRounded;
    final color = _attendanceQualityColor(hasSessions ? pct : 72);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.softGrey.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.softGrey),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AttendanceListTitleStringsColumn(
              title: row.listTitle,
              subtitle: row.listSubtitle,
            ),
            const SizedBox(height: 10),
            if (!hasSessions)
              Text(
                'No completed sessions yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '$pct%',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: color,
                      height: 1,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${stats.present} present of ${stats.total} sessions',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: pct / 100.0,
                            minHeight: 8,
                            color: color,
                            backgroundColor: AppTheme.softGrey,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openChangePasswordDialog(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ChangePasswordScreen(),
      ),
    );
  }

  Widget _buildProfileCard(
    BuildContext context,
    AuthRepository auth, {
    required String? email,
    required String? reg,
  }) {
    if (!auth.adminCheckDone || !auth.lecturerCheckDone) {
      return _buildLoadingProfileCard(context, email: email);
    }
    if (auth.isAdmin) {
      return _buildAdminProfileCard(
        context,
        auth,
        email: email,
        reg: reg,
      );
    }
    return _buildStudentProfileCard(
      context,
      auth,
      email: email,
      reg: reg,
    );
  }

  Widget _buildLoadingProfileCard(BuildContext context, {required String? email}) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          children: [
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Loading your profile…',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (email != null && email.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      email.trim(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStudentProfileCard(
    BuildContext context,
    AuthRepository auth, {
    required String? email,
    required String? reg,
  }) {
    final theme = Theme.of(context);
    final fullName = (_profile?['fullName'] ?? auth.currentFullName)?.trim();
    final displayName =
        (fullName != null && fullName.isNotEmpty) ? fullName : 'Student';
    final initials = _initialsFrom(fullName, email);
    final hasAnyList = _attendanceByList.isNotEmpty;
    final listsWithSessions =
        _attendanceByList.where((e) => e.stats.total > 0).toList();
    final headerPct = listsWithSessions.isEmpty
        ? 72
        : (listsWithSessions
                    .map((e) => e.stats.percentRounded)
                    .reduce((a, b) => a + b) /
                listsWithSessions.length)
            .round();
    final rateColor = _attendanceQualityColor(headerPct);

    return Card(
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
                  _attendanceQualityColor(headerPct)
                      .withValues(alpha: 0.45),
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
                    backgroundColor: Colors.white.withValues(alpha: 0.92),
                    foregroundColor: AppTheme.primary,
                    child: Text(
                      initials,
                      style: theme.textTheme.headlineSmall?.copyWith(
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
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          email ?? '—',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white.withValues(alpha: 0.92),
                          ),
                        ),
                        if (reg != null && reg.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            reg,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: Colors.white.withValues(alpha: 0.85),
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.school_rounded,
                              size: 18,
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Student account',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: Colors.white.withValues(alpha: 0.88),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.event_available_rounded,
                        size: 22, color: rateColor),
                    const SizedBox(width: 8),
                    Text(
                      'Class attendance',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (!_attendanceStatsLoaded)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else if (reg == null || reg.isEmpty)
                  Text(
                    'Add your registration number in your account details so '
                    'we can match you to class lists and show attendance per class.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.45,
                    ),
                  )
                else if (!hasAnyList)
                  Text(
                    'You are not on any class lists yet. After you sign in to a '
                    'class, each list will show your attendance percentage here.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.45,
                    ),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Attendance by class list (completed sessions only).',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (var i = 0; i < _attendanceByList.length; i++) ...[
                        if (i > 0) const SizedBox(height: 12),
                        _buildPerListAttendanceTile(
                          context,
                          _attendanceByList[i],
                        ),
                      ],
                    ],
                  ),
                const SizedBox(height: 20),
                settingsSignOutButton(
                  context: context,
                  auth: auth,
                  email: email,
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdminProfileCard(
    BuildContext context,
    AuthRepository auth, {
    required String? email,
    required String? reg,
  }) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            color: AppTheme.primary.withValues(alpha: 0.08),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: AppTheme.primary.withValues(alpha: 0.15),
                  child: Icon(
                    auth.isQaStaff
                        ? Icons.fact_check_outlined
                        : Icons.admin_panel_settings_rounded,
                    color: AppTheme.primary,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        auth.resolvedRole.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        email?.trim().isNotEmpty == true ? email!.trim() : '—',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ((_profile?['fullName'] ?? auth.currentFullName)
                        ?.trim()
                        .isNotEmpty ==
                    true) ...[
                  Text(
                    'Full name',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _profile?['fullName'] ?? auth.currentFullName ?? '',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                Text(
                  'Registration number',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  reg?.trim().isNotEmpty == true ? reg!.trim() : '—',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          settingsSignOutButton(
            context: context,
            auth: auth,
            email: email,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthRepository.instance,
      builder: (context, _) {
        final auth = AuthRepository.instance;
        if (auth.roleCheckDone && auth.resolvedRole == UserRole.lecturer) {
          return const LecturerSettingsScreen();
        }
        final reg = auth.currentRegistrationNumber;
        final email = _profile?['email'] ?? auth.currentEmail;
        final visibleEmail = StaffAuthEmail.syntheticEmailToStaffNumber(
                  email ?? '',
                ) !=
                null
            ? '—'
            : email;

        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Settings',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            const SizedBox(height: 6),
            Text(
              auth.adminCheckDone && auth.isAdmin
                  ? (auth.isQaStaff
                      ? 'Your QA staff account'
                      : 'Your administrator account')
                  : 'Your account and attendance',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
            ),
            const SizedBox(height: 22),
            _buildProfileCard(
              context,
              auth,
              email: visibleEmail,
              reg: reg,
            ),
            const SizedBox(height: 16),
            Text(
              'Security',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary,
                  ),
            ),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading:
                        Icon(Icons.lock_outline_rounded, color: AppTheme.primary),
                    title: const Text('Change password'),
                    subtitle: const Text('Update the password for this account'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _openChangePasswordDialog(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'About',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary,
                  ),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading:
                    Icon(Icons.school_rounded, color: AppTheme.primary),
                title: const Text('Kampala International University'),
                subtitle: const Text(
                  'Class notices and attendance use this app for on-campus sessions.',
                ),
              ),
            ),
            ],
          ),
        );
      },
    );
  }
}
