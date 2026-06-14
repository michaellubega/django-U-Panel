import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/auth/staff_auth_email.dart';
import '../../core/auth/user_role.dart';
import 'change_password_screen.dart';
import 'update_profile_screen.dart';
import '../../core/theme/app_theme.dart';
import 'student_class_attendance_detail_screen.dart';
import 'settings_shared.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/student_attendance_live_sync.dart';
import '../attendance/attendance_list_title.dart';
import '../attendance/models/attendance_models.dart';
import 'lecturer_settings_screen.dart';
import 'qa_staff_settings_screen.dart';
import '../campus_presence/kiu_admin_ui.dart';
import '../../core/navigation/app_section.dart';
import '../../core/navigation/screen_refresh.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.shellSection = AppSection.settings});

  final AppSection shellSection;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  static const Duration _autoRefreshInterval = Duration(seconds: 5);
  Timer? _autoRefreshTimer;
  ValueNotifier<AppSection>? _sectionNotifier;
  VoidCallback? _sectionListener;
  bool _profileRtdRefreshInFlight = false;

  Map<String, String>? _profile;
  bool _attendanceStatsLoaded = false;
  List<AttendanceListRollStats> _attendanceByList = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AuthRepository.instance.addListener(_onAuth);
    AttendanceRepository.instance.addListener(_onAttendanceStore);
    AppConnectivity.instance.addListener(_onConnectivityChanged);
    _applyCachedAttendanceStats();
    _loadProfile();
    unawaited(_refreshProfileAndStats());
    _autoRefreshTimer =
        Timer.periodic(_autoRefreshInterval, (_) => _refreshProfileAndStats());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindSectionVisibilityListener();
  }

  void _bindSectionVisibilityListener() {
    final scope = ScreenRefreshScope.maybeOf(context);
    final notifier = scope?.currentSection;
    if (notifier == _sectionNotifier) return;
    _sectionNotifier?.removeListener(_onShellSectionChanged);
    _sectionNotifier = notifier;
    _sectionListener ??= _onShellSectionChanged;
    notifier?.addListener(_sectionListener!);
  }

  void _onShellSectionChanged() {
    if (_sectionNotifier?.value == widget.shellSection) {
      unawaited(_refreshFromRtdOnVisible());
    }
  }

  Future<void> _refreshFromRtdOnVisible() async {
    if (_profileRtdRefreshInFlight) return;
    _profileRtdRefreshInFlight = true;
    try {
      await StudentAttendanceLiveSync.refreshProfileOnVisible();
      if (mounted) _applyCachedAttendanceStats();
    } finally {
      _profileRtdRefreshInFlight = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoRefreshTimer?.cancel();
    if (_sectionListener != null) {
      _sectionNotifier?.removeListener(_sectionListener!);
    }
    AuthRepository.instance.removeListener(_onAuth);
    AttendanceRepository.instance.removeListener(_onAttendanceStore);
    AppConnectivity.instance.removeListener(_onConnectivityChanged);
    super.dispose();
  }

  void _onAttendanceStore() {
    _applyCachedAttendanceStats();
  }

  void _onConnectivityChanged() {
    if (AppConnectivity.instance.isOnline) {
      unawaited(_refreshFromRtdOnVisible());
    } else {
      unawaited(
        AttendanceRepository.instance.loadStudentAttendanceForProfile(
          force: false,
        ),
      );
    }
    _applyCachedAttendanceStats();
  }

  void _applyCachedAttendanceStats() {
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

    final reg = auth.currentRegistrationNumber?.trim();
    if (reg == null || reg.isEmpty) {
      if (mounted) {
        setState(() {
          _attendanceStatsLoaded = true;
          _attendanceByList = const [];
        });
      }
      return;
    }

    final repo = AttendanceRepository.instance;
    final hasRtdStats =
        AttendanceStore.hasRtdRollStatsForRegistrationNormalized(reg);
    final hasStudentData = repo.hasCachedStore ||
        AttendanceStore.hasAttendanceDataForRegistrationNormalized(reg) ||
        AttendanceStore.hasStudentSessionHistoryForRegistrationNormalized(reg) ||
        hasRtdStats;
    if (!hasStudentData) {
      unawaited(
        AttendanceRepository.instance.loadStudentAttendanceForProfile(
          force: false,
        ),
      );
      return;
    }

    final stats =
        AttendanceStore.rollStatsPerListForRegistrationNormalized(reg);
    final enrolled =
        AttendanceStore.enrolledListIdsForRegistrationNormalized(reg);
    final missingListMetadata = enrolled.isNotEmpty &&
        enrolled.any((id) => AttendanceStore.listById(id) == null);
    if (stats.isEmpty && missingListMetadata) {
      if (mounted) setState(() => _attendanceStatsLoaded = false);
      unawaited(
        AttendanceRepository.instance.loadStudentAttendanceForProfile(
          force: false,
        ),
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      _attendanceStatsLoaded = true;
      _attendanceByList = stats;
    });
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
      unawaited(_refreshFromRtdOnVisible());
      _refreshProfileAndStats();
    }
  }

  Future<void> _refreshProfileAndStats({bool forceAttendance = false}) async {
    try {
      if (!forceAttendance) {
        await _refreshFromRtdOnVisible();
      }
      await _loadProfile();
      await _loadAttendanceStats(force: forceAttendance);
    } catch (_) {
      // Keep profile usable if background refresh fails.
    }
  }

  Future<void> _loadProfile() async {
    final p = await AuthRepository.instance.profileForCurrentUser();
    if (mounted) setState(() => _profile = p);
  }

  Future<void> _loadAttendanceStats({bool force = false}) async {
    final auth = AuthRepository.instance;
    if (auth.adminCheckDone && auth.isAdmin) return;
    if (auth.lecturerCheckDone && auth.isLecturer && !auth.isAdmin) return;
    final reg = auth.currentRegistrationNumber?.trim();
    if (reg == null || reg.isEmpty) return;

    await AttendanceRepository.instance.warmFromLocalSnapshot();
    _applyCachedAttendanceStats();

    if (!force) {
      unawaited(() async {
        await AttendanceRepository.instance.loadStudentAttendanceForProfile(
          force: false,
        );
        if (mounted) _applyCachedAttendanceStats();
      }());
      return;
    }

    await AttendanceRepository.instance.loadStudentAttendanceForProfile(
      force: true,
    );
    _applyCachedAttendanceStats();
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

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => StudentClassAttendanceDetailScreen(
                listId: row.listId,
                listTitle: row.listTitle,
                listSubtitle: row.listSubtitle,
              ),
            ),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: DecoratedBox(
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
                  Icon(
                    Icons.chevron_right_rounded,
                    color: AppTheme.textSecondary.withValues(alpha: 0.7),
                  ),
                ],
              ),
            if (hasSessions) ...[
              const SizedBox(height: 8),
              Text(
                'Tap for session records and comments',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
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

  Future<void> _openUpdateProfile(BuildContext context) async {
    final updated = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const UpdateProfileScreen(),
      ),
    );
    if (updated == true && mounted) {
      await _refreshProfileAndStats();
    }
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
    if (auth.isAdmin || auth.isKiuAdmin) {
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
    var headerPct = 72;
    if (listsWithSessions.isNotEmpty) {
      headerPct = (listsWithSessions
                  .map((e) => e.stats.percentRounded)
                  .reduce((a, b) => a + b) /
              listsWithSessions.length)
          .round();
    } else if (reg != null && reg.trim().isNotEmpty) {
      final overall =
          AttendanceStore.rollStatsForRegistrationNormalized(reg.trim());
      if (overall.total > 0) {
        headerPct = overall.percentRounded;
      }
    }
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
    final fullName = (_profile?['fullName'] ?? auth.currentFullName)?.trim();
    final isKiu = auth.isKiuAdmin;
    final isQa = auth.isQaStaff;
    final displayName = (fullName != null && fullName.isNotEmpty)
        ? fullName
        : (isKiu
            ? 'KIU Administrator'
            : isQa
                ? 'QA staff'
                : auth.resolvedRole.label);
    final initials = settingsInitialsFrom(fullName, email);
    final jobTitle = (_profile?[AuthRepository.kiuAdminJobTitleField] ??
            auth.currentKiuAdminJobTitle)
        ?.trim();
    final staffNumber = auth.currentStaffNumber?.trim();
    final gradient = isKiu
        ? KiuAdminUi.gradient
        : LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppTheme.primary.withValues(alpha: 0.85),
              AppTheme.primary,
            ],
          );
    final accountIcon = isKiu
        ? Icons.admin_panel_settings_rounded
        : isQa
            ? Icons.fact_check_outlined
            : Icons.shield_rounded;
    final accountLabel = isKiu
        ? 'KIU administrator account'
        : isQa
            ? 'QA staff account'
            : 'Administrator account';

    final detailChips = <Widget>[];
    if (staffNumber != null && staffNumber.isNotEmpty) {
      detailChips.add(
        settingsDetailChip(
          icon: Icons.badge_outlined,
          label: 'Staff number',
          value: staffNumber,
        ),
      );
    }
    if (reg != null && reg.trim().isNotEmpty) {
      detailChips.add(
        settingsDetailChip(
          icon: Icons.numbers_rounded,
          label: 'Registration number',
          value: reg.trim(),
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          settingsProfileHero(
            context: context,
            displayName: displayName,
            email: email,
            accountLabel: accountLabel,
            initials: initials,
            gradient: gradient,
            accountIcon: accountIcon,
            badgeLabel: isKiu ? 'KIU ADMIN' : null,
            secondaryLine: isKiu && jobTitle != null && jobTitle.isNotEmpty
                ? jobTitle
                : null,
          ),
          if (detailChips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < detailChips.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    detailChips[i],
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthRepository.instance,
      builder: (context, _) {
        final auth = AuthRepository.instance;
        if (auth.roleCheckDone && auth.isQaStaff) {
          return QaStaffSettingsScreen(shellSection: widget.shellSection);
        }
        if (auth.roleCheckDone &&
            auth.resolvedRole == UserRole.lecturer &&
            !auth.isKiuAdmin) {
          return LecturerSettingsScreen(shellSection: widget.shellSection);
        }
        final reg = auth.currentRegistrationNumber;
        final email = _profile?['email'] ?? auth.currentEmail;
        final visibleEmail = StaffAuthEmail.syntheticEmailToStaffNumber(
                  email ?? '',
                ) !=
                null
            ? '—'
            : email;

        Future<void> refreshSettings() async {
          await _refreshFromRtdOnVisible();
          await _refreshProfileAndStats(forceAttendance: true);
        }

        return ScreenRefreshRegistrar(
          section: widget.shellSection,
          onRefresh: refreshSettings,
          child: PullToRefreshBody(
            onRefresh: refreshSettings,
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                auth.isKiuAdmin ? 'Profile' : 'Settings',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            const SizedBox(height: 6),
            Text(
              auth.isKiuAdmin
                  ? 'Your KIU administrator account and security'
                  : auth.adminCheckDone && auth.isAdmin
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
            const SizedBox(height: 18),
            settingsSecurityCard(
              context: context,
              onUpdateProfile: () => _openUpdateProfile(context),
              onChangePassword: () => _openChangePasswordDialog(context),
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
