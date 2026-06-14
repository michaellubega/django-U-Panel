import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/auth/user_role.dart';
import '../../core/constants/app_constants.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/attendance_list_hierarchy.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/models/attendance_models.dart';
import '../notices/create_notice_screen.dart';
import '../notices/data/notices_repository.dart';
import '../attendance/attendance_screen.dart';
import '../attendance/qa_overdue_attendance_screen.dart';
import '../attendance/today_attendance_list_filter.dart';
import '../attendance/today_attendance_lists_screen.dart';
import '../lesson_insights/lesson_insights_dashboard_section.dart';
import '../../core/navigation/app_navigator.dart';
import '../../core/navigation/app_section.dart';
import '../../core/navigation/screen_refresh.dart';
import '../campus_presence/admin_campus_absent_list_screen.dart';
import '../campus_presence/admin_campus_presence_card.dart';
import '../campus_presence/campus_presence_log_screen.dart';
import '../campus_presence/data/campus_presence_repository.dart';
import '../campus_presence/models/campus_presence_models.dart';
import 'dashboard_shared_widgets.dart';
import 'live_sessions_list_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.shellSection = AppSection.dashboard});

  final AppSection shellSection;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = true;
  bool _refreshing = false;
  String? _loadError;
  DateTime? _lastUpdated;
  AdminCampusPresenceDashboardSummary _adminCampusPresence =
      const AdminCampusPresenceDashboardSummary(
    totalAdmins: 0,
    presentToday: 0,
    absentToday: 0,
  );

  @override
  void initState() {
    super.initState();
    _loading = !AttendanceRepository.instance.hasCachedStore;
    unawaited(_refresh());
  }

  Future<void> _refresh({bool forceNetwork = false}) async {
    await AttendanceRepository.instance.warmFromLocalSnapshot();
    final blocking = !AttendanceRepository.instance.hasCachedStore;
    setState(() {
      _loading = blocking;
      _refreshing = forceNetwork && !blocking;
      _loadError = null;
    });
    try {
      if (forceNetwork || blocking) {
        await AttendanceRepository.instance.bootstrapLoadIfNeeded(
          force: forceNetwork,
        );
      } else {
        unawaited(AttendanceRepository.instance.bootstrapLoadIfNeeded());
      }
      AttendanceRepository.instance.prefetchActiveListDetails();
      final auth = AuthRepository.instance;
      if (auth.adminCheckDone && auth.isAdmin) {
        _adminCampusPresence = await CampusPresenceRepository.instance
            .fetchTodayAdminPresenceDashboardSummary();
      }
      _lastUpdated = DateTime.now();
      _loadError = null;
    } catch (e) {
      _loadError = '$e';
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _refreshing = false;
      });
    }
  }

  void _openLiveSessionsList(BuildContext context) {
    pushAppPage<void>(
      context,
      LiveSessionsListScreen(
        onSessionTap: (s) => _openSession(context, s),
      ),
    );
  }

  void _openSession(BuildContext context, AttendanceSession session) {
    final list = AttendanceStore.listById(session.listId);
    if (list == null) {
      DashboardShellNav.go(context, AppSection.attendance);
      return;
    }
    pushAppPage<void>(
      context,
      StartSessionScreen(
        list: list,
        resumeSession: session,
      ),
    );
  }

  bool _isAdmin() =>
      AuthRepository.instance.adminCheckDone && AuthRepository.instance.isAdmin;

  static bool _isSameLocalDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  _DashboardMetrics _metrics() {
    final now = DateTime.now();
    final sessionIds = AttendanceStore.sessions.map((s) => s.id).toSet();
    var presentToday = 0;
    var absentToday = 0;
    for (final r in AttendanceStore.attendanceRecords) {
      if (!sessionIds.contains(r.sessionId)) continue;
      if (!_isSameLocalDay(r.timestamp, now)) continue;
      if (r.present) {
        presentToday++;
      } else {
        absentToday++;
      }
    }

    var draftLists = 0;
    var activeLists = 0;
    var closedLists = 0;
    for (final l in attendanceListsForCurrentStaff()) {
      switch (l.status) {
        case AttendanceListStatus.draft:
          draftLists++;
          break;
        case AttendanceListStatus.active:
          activeLists++;
          break;
        case AttendanceListStatus.closed:
          closedLists++;
          break;
      }
    }

    final liveSessions =
        AttendanceStore.sessions.where((s) => s.isActive).toList()
          ..sort((a, b) => a.endTime.compareTo(b.endTime));

    return _DashboardMetrics(
      presentToday: presentToday,
      absentToday: absentToday,
      draftLists: draftLists,
      activeLists: activeLists,
      closedLists: closedLists,
      rosterStudents: AttendanceStore.students.length,
      listEnrollments: AttendanceStore.signIns.length,
      liveSessions: liveSessions,
    );
  }

  _StudentDashViewModel _studentViewModel() {
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim() ?? '';
    if (reg.isEmpty) {
      return const _StudentDashViewModel(
        hasRegistration: false,
        onRoster: false,
        rollStats: AttendanceRollStats(present: 0, total: 0),
        signedListCount: 0,
        presentToday: 0,
        absentToday: 0,
        liveSessions: <AttendanceSession>[],
      );
    }
    final student = AttendanceStore.findStudentByReg(reg);
    if (student == null) {
      return const _StudentDashViewModel(
        hasRegistration: true,
        onRoster: false,
        rollStats: AttendanceRollStats(present: 0, total: 0),
        signedListCount: 0,
        presentToday: 0,
        absentToday: 0,
        liveSessions: <AttendanceSession>[],
      );
    }
    final sid = student.id;
    final signedListIds = <String>{
      for (final si in AttendanceStore.signIns)
        if (si.studentId == sid) si.listId,
    };
    final sessionIds = AttendanceStore.sessions
        .where((s) => signedListIds.contains(s.listId))
        .map((s) => s.id)
        .toSet();

    final now = DateTime.now();
    var presentToday = 0;
    var absentToday = 0;
    for (final r in AttendanceStore.attendanceRecords) {
      if (r.studentId != sid) continue;
      if (!sessionIds.contains(r.sessionId)) continue;
      if (!_isSameLocalDay(r.timestamp, now)) continue;
      if (r.present) {
        presentToday++;
      } else {
        absentToday++;
      }
    }

    final liveSessions =
        AttendanceStore.sessions.where((s) {
      if (!s.isActive) return false;
      return signedListIds.contains(s.listId);
    }).toList()
          ..sort((a, b) => a.endTime.compareTo(b.endTime));

    final roll = AttendanceStore.rollStatsForRegistrationNormalized(reg);

    return _StudentDashViewModel(
      hasRegistration: true,
      onRoster: true,
      rollStats: roll,
      signedListCount: signedListIds.length,
      presentToday: presentToday,
      absentToday: absentToday,
      liveSessions: liveSessions,
    );
  }

  String _formatNoticeTime(BuildContext context, NoticeRecord n) {
    final loc = MaterialLocalizations.of(context);
    final d = n.scheduledFor ?? n.createdAt;
    final dateText = loc.formatShortDate(d);
    final timeText = loc.formatTimeOfDay(TimeOfDay.fromDateTime(d));
    return '$dateText · $timeText';
  }

  String _welcomeDisplayName() {
    final full = AuthRepository.instance.currentFullName?.trim();
    if (full != null && full.isNotEmpty) {
      return full.split(RegExp(r'\s+')).first;
    }
    final email = AuthRepository.instance.currentUserEmail?.trim();
    if (email != null && email.isNotEmpty) {
      return email.split('@').first;
    }
    return 'there';
  }

  String? _welcomeRoleLabel() {
    final auth = AuthRepository.instance;
    if (auth.isQaStaff) return 'QA staff';
    if (auth.isFullAdministrator) return 'Administrator';
    if (auth.isAdmin) return 'Admin';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AuthRepository.instance,
        AppConnectivity.instance,
        AttendanceRepository.instance,
      ]),
      builder: (context, _) {
            final admin = _isAdmin();
            if (!admin) {
              return _NonAdminDashboardPlaceholder(
                role: AuthRepository.instance.resolvedRole,
              );
            }
            final offline = !AppConnectivity.instance.isOnline;
            final m = _metrics();

            final liveCount = m.liveSessions.length;

            return ScreenRefreshRegistrar(
              section: widget.shellSection,
              onRefresh: () => _refresh(forceNetwork: true),
              child: RefreshIndicator(
              onRefresh: () => _refresh(forceNetwork: true),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DashboardLiveHeader(
                      title: 'Dashboard',
                      welcomeName: _welcomeDisplayName(),
                      roleLabel: _welcomeRoleLabel(),
                      compact: true,
                      liveCount: liveCount,
                      lastUpdated: _lastUpdated,
                      refreshing: _loading || _refreshing,
                      onRefresh: () => unawaited(_refresh(forceNetwork: true)),
                    ),
                    if (offline) ...[
                      const SizedBox(height: 8),
                      const _OfflineHint(),
                    ],
                    if (_loadError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _loadError!,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: AppTheme.error),
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (_loading && !AttendanceRepository.instance.hasCachedStore)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else ...[
                      if (AuthRepository.instance.isKiuAdmin) ...[
                        const AdminCampusPresenceCard(),
                        const SizedBox(height: 16),
                      ],
                      _AdminStatsRow(
                        metrics: m,
                        campusSummary: _adminCampusPresence,
                        onLive: () => _openLiveSessionsList(context),
                        onPresent: () => openTodayRollClassLists(
                          context,
                          filter: TodayRollPresenceFilter.present,
                        ),
                        onAbsent: () => openTodayRollClassLists(
                          context,
                          filter: TodayRollPresenceFilter.absent,
                        ),
                        onActiveLists: () => DashboardShellNav.go(
                          context,
                          AppSection.attendance,
                        ),
                        onAdminPresent: () {
                          Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => const CampusPresenceLogScreen(),
                            ),
                          );
                        },
                        onAdminAbsent: () {
                          Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  const AdminCampusAbsentListScreen(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      _DashboardAttendanceAndClassListsRow(
                        metrics: m,
                        presentToday: m.presentToday,
                        absentToday: m.absentToday,
                        onPresentTap: () => openTodayRollClassLists(
                          context,
                          filter: TodayRollPresenceFilter.present,
                        ),
                        onAbsentTap: () => openTodayRollClassLists(
                          context,
                          filter: TodayRollPresenceFilter.absent,
                        ),
                        onSeeAttendance: () => DashboardShellNav.go(
                          context,
                          AppSection.attendance,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Quick actions',
                        style: DashboardCardText.itemTitle(
                          Theme.of(context).textTheme,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DashboardCompactQuickActionsRow(
                        actions: [
                          DashboardCompactQuickAction(
                            icon: Icons.timer_off_rounded,
                            label: 'Overdue',
                            color: AppTheme.warning,
                            onTap: () {
                              Navigator.of(context).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      const QaOverdueAttendanceScreen(),
                                ),
                              );
                            },
                          ),
                          DashboardCompactQuickAction(
                            icon: Icons.people_alt_rounded,
                            label: 'Attendance',
                            onTap: () => DashboardShellNav.go(
                              context,
                              AppSection.attendance,
                            ),
                          ),
                          DashboardCompactQuickAction(
                            icon: Icons.add_circle_outline_rounded,
                            label: 'New notice',
                            onTap: () {
                              Navigator.of(context).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (_) => const CreateNoticeScreen(),
                                ),
                              );
                            },
                          ),
                          DashboardCompactQuickAction(
                            icon: Icons.analytics_rounded,
                            label: 'Reports',
                            onTap: () => DashboardShellNav.go(
                              context,
                              AppSection.reports,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      const QaLessonInsightsDashboardCard(),
                    ],
                  ],
                ),
              ),
            ),
            );
      },
    );
  }
}

class _NonAdminDashboardPlaceholder extends StatelessWidget {
  const _NonAdminDashboardPlaceholder({required this.role});

  final UserRole role;

  @override
  Widget build(BuildContext context) {
    final message = switch (role) {
      UserRole.lecturer || UserRole.kiuAdmin =>
        'Use the Home tab for your overview.',
      _ => 'Use Attendance to sign in to class sessions.',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: AppTheme.textSecondary,
              ),
        ),
      ),
    );
  }
}

class _DashboardAttendanceAndClassListsRow extends StatelessWidget {
  const _DashboardAttendanceAndClassListsRow({
    required this.metrics,
    required this.presentToday,
    required this.absentToday,
    required this.onPresentTap,
    required this.onAbsentTap,
    required this.onSeeAttendance,
  });

  final _DashboardMetrics metrics;
  final int presentToday;
  final int absentToday;
  final VoidCallback onPresentTap;
  final VoidCallback onAbsentTap;
  final VoidCallback onSeeAttendance;

  static const _attendanceWidth = 360.0;
  static const _besideBreakpoint = 720.0;

  @override
  Widget build(BuildContext context) {
    final attendanceCard = DashboardAttendanceOverviewCard(
      presentToday: presentToday,
      absentToday: absentToday,
      embeddedInRow: true,
      onPresentTap: onPresentTap,
      onAbsentTap: onAbsentTap,
    );
    final classListsCard = _DashboardClassListsCompactCard(
      metrics: metrics,
      onSeeAttendance: onSeeAttendance,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final beside = constraints.maxWidth >= _besideBreakpoint;
        if (!beside) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              attendanceCard,
              const SizedBox(height: 12),
              classListsCard,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: _attendanceWidth, child: attendanceCard),
            const SizedBox(width: 16),
            Expanded(child: classListsCard),
          ],
        );
      },
    );
  }
}

class _DashboardClassListsCompactCard extends StatelessWidget {
  const _DashboardClassListsCompactCard({
    required this.metrics,
    required this.onSeeAttendance,
  });

  final _DashboardMetrics metrics;
  final VoidCallback onSeeAttendance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cells = [
      _ClassListMetric('Active', metrics.activeLists, AppTheme.accent),
      _ClassListMetric('Closed', metrics.closedLists, AppTheme.textSecondary),
      _ClassListMetric(
        'Roster students',
        metrics.rosterStudents,
        AppTheme.primary,
      ),
      _ClassListMetric(
        'Enrollments',
        metrics.listEnrollments,
        AppTheme.primary,
      ),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Class lists',
                    style: DashboardCardText.cardSection(theme.textTheme),
                  ),
                ),
                TextButton(
                  onPressed: onSeeAttendance,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('Open'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final twoCol = constraints.maxWidth >= 260;
                if (!twoCol) {
                  return Column(
                    children: [
                      for (var i = 0; i < cells.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        _ClassListMetricTile(metric: cells[i]),
                      ],
                    ],
                  );
                }
                return Column(
                  children: [
                    for (var row = 0; row < cells.length; row += 2) ...[
                      if (row > 0) const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _ClassListMetricTile(metric: cells[row]),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: row + 1 < cells.length
                                ? _ClassListMetricTile(metric: cells[row + 1])
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ClassListMetric {
  const _ClassListMetric(this.label, this.value, this.color);

  final String label;
  final int value;
  final Color color;
}

class _ClassListMetricTile extends StatelessWidget {
  const _ClassListMetricTile({required this.metric});

  final _ClassListMetric metric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: metric.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: metric.color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${metric.value}',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: AppTheme.primary,
              height: 1.1,
              fontSize: DashboardCardText.metricValueSize,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            metric.label,
            style: DashboardCardText.captionSecondary(theme.textTheme),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _DashboardMetrics {
  const _DashboardMetrics({
    required this.presentToday,
    required this.absentToday,
    required this.draftLists,
    required this.activeLists,
    required this.closedLists,
    required this.rosterStudents,
    required this.listEnrollments,
    required this.liveSessions,
  });

  final int presentToday;
  final int absentToday;
  final int draftLists;
  final int activeLists;
  final int closedLists;
  final int rosterStudents;
  final int listEnrollments;
  final List<AttendanceSession> liveSessions;
}

class _OfflineHint extends StatelessWidget {
  const _OfflineHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_off_rounded, color: AppTheme.warning, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Figures reflect the last data loaded on this device. Pull to refresh when you are back online.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminStatsRow extends StatelessWidget {
  const _AdminStatsRow({
    required this.metrics,
    required this.campusSummary,
    required this.onLive,
    required this.onPresent,
    required this.onAbsent,
    required this.onActiveLists,
    required this.onAdminPresent,
    required this.onAdminAbsent,
  });

  final _DashboardMetrics metrics;
  final AdminCampusPresenceDashboardSummary campusSummary;
  final VoidCallback onLive;
  final VoidCallback onPresent;
  final VoidCallback onAbsent;
  final VoidCallback onActiveLists;
  final VoidCallback onAdminPresent;
  final VoidCallback onAdminAbsent;

  static const _sixTileRowMinWidth = 980.0;
  static const _tileHeight = 108.0;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      DashboardStatTile(
        label: 'Live sessions',
        value: '${metrics.liveSessions.length}',
        icon: Icons.sensors_rounded,
        color: AppTheme.accent,
        highlight: metrics.liveSessions.isNotEmpty,
        fillHeight: true,
        dense: true,
        onTap: onLive,
      ),
      DashboardStatTile(
        label: 'Present today',
        value: '${metrics.presentToday}',
        icon: Icons.how_to_reg_rounded,
        color: AppTheme.success,
        fillHeight: true,
        dense: true,
        onTap: onPresent,
      ),
      DashboardStatTile(
        label: 'Absent today',
        value: '${metrics.absentToday}',
        icon: Icons.person_off_rounded,
        color: AppTheme.error,
        fillHeight: true,
        dense: true,
        onTap: onAbsent,
      ),
      DashboardStatTile(
        label: 'Active lists',
        value: '${metrics.activeLists}',
        icon: Icons.class_rounded,
        color: AppTheme.primary,
        fillHeight: true,
        dense: true,
        onTap: onActiveLists,
      ),
      DashboardStatTile(
        label: 'Admins present',
        value: '${campusSummary.presentToday}',
        icon: Icons.badge_rounded,
        color: AppTheme.success,
        fillHeight: true,
        dense: true,
        onTap: onAdminPresent,
      ),
      DashboardStatTile(
        label: 'Admins absent',
        value: '${campusSummary.absentToday}',
        icon: Icons.badge_outlined,
        color: AppTheme.primary,
        fillHeight: true,
        dense: true,
        onTap: onAdminAbsent,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final useWideRow = constraints.maxWidth >= _sixTileRowMinWidth;
        if (useWideRow) {
          return SizedBox(
            height: _tileHeight,
            child: Row(
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: tiles[i]),
                ],
              ],
            ),
          );
        }
        return DashboardMetricTilesStrip(
          tiles: tiles,
          tileWidth: 128,
          tileHeight: _tileHeight,
        );
      },
    );
  }
}

class _StatItem {
  _StatItem(this.label, this.value, this.icon, this.color);

  final String label;
  final String value;
  final IconData icon;
  final Color color;
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.item});

  final _StatItem item;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.width < 400;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: item.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(item.icon, size: 24, color: item.color),
                ),
                Text(
                  item.value,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: AppTheme.primary,
                        fontSize: DashboardCardText.metricValueLargeSize,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              item.label,
              style: DashboardCardText.captionSecondary(
                Theme.of(context).textTheme,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveSessionsCard extends StatelessWidget {
  const _LiveSessionsCard({
    required this.sessions,
    this.onSessionTap,
    this.onSeeAll,
    this.onSeeAttendance,
  });

  final List<AttendanceSession> sessions;
  final void Function(AttendanceSession session)? onSessionTap;
  final VoidCallback? onSeeAll;
  final VoidCallback? onSeeAttendance;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Live check-in sessions',
      trailing: sessions.isEmpty
          ? (onSeeAttendance == null
              ? null
              : TextButton(
                  onPressed: onSeeAttendance,
                  child: const Text('Attendance'),
                ))
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onSeeAll != null)
                  TextButton(
                    onPressed: onSeeAll,
                    child: const Text('View all'),
                  ),
                if (onSeeAttendance != null)
                  TextButton(
                    onPressed: onSeeAttendance,
                    child: const Text('Attendance'),
                  ),
              ],
            ),
      children: [
        if (sessions.isEmpty)
          Text(
            'No open sessions right now. Start one from Attendance.',
            style: DashboardCardText.bodySecondary(Theme.of(context).textTheme),
          )
        else
          ...sessions.take(8).map((s) {
            final list = AttendanceStore.listById(s.listId);
            final title = list?.displayTitle ?? 'Class list ${s.listId}';
            final mins = s.endTime.difference(DateTime.now()).inMinutes;
            final ends = mins < 0 ? 'ending' : '${mins.clamp(0, 9999)} min left';
            final tap = onSessionTap;
            if (tap != null) {
              return DashboardTapTile(
                icon: Icons.sensors_rounded,
                iconColor: AppTheme.accent,
                title: title,
                subtitle:
                    'Code ${normalizeSessionCodeInput(s.sessionCode)} · $ends · Tap to open',
                onTap: () => tap(s),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '$title · Code ${normalizeSessionCodeInput(s.sessionCode)} · $ends',
                style: DashboardCardText.bodySecondary(
                  Theme.of(context).textTheme,
                ),
              ),
            );
          }),
      ],
    );
  }
}

class _RecentNoticesCard extends StatelessWidget {
  const _RecentNoticesCard({
    required this.notices,
    required this.formatNoticeTime,
    this.onSeeNotices,
  });

  final List<NoticeRecord> notices;
  final String Function(BuildContext context, NoticeRecord n) formatNoticeTime;
  final VoidCallback? onSeeNotices;

  @override
  Widget build(BuildContext context) {
    final top = notices.take(6).toList();
    return _SectionCard(
      title: 'Recent notices',
      trailing: onSeeNotices == null
          ? null
          : TextButton(
              onPressed: onSeeNotices,
              child: const Text('See all'),
            ),
      children: [
        if (top.isEmpty)
          Text(
            'No notices yet.',
            style: DashboardCardText.bodySecondary(Theme.of(context).textTheme),
          )
        else
          ...top.map((n) {
            final aud = n.audience == NoticeAudienceKind.allAppUsers
                ? 'All users'
                : n.audience == NoticeAudienceKind.kiuAdmins
                    ? 'KIU administrators'
                    : n.audience == NoticeAudienceKind.student
                        ? 'Individual student'
                        : 'List: ${n.targetListTitle ?? n.targetListId ?? '—'}';
            final title =
                n.title.trim().isEmpty ? '(No title)' : n.title.trim();
            final subtitle =
                '$aud · ${n.author} · ${formatNoticeTime(context, n)}';
            final see = onSeeNotices;
            if (see != null) {
              return DashboardTapTile(
                icon: Icons.campaign_outlined,
                title: title,
                subtitle: subtitle,
                onTap: see,
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: DashboardCardText.itemTitle(Theme.of(context).textTheme),
                  ),
                  Text(
                    subtitle,
                    style: DashboardCardText.captionSecondary(
                      Theme.of(context).textTheme,
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }
}

class _StudentDashViewModel {
  const _StudentDashViewModel({
    required this.hasRegistration,
    required this.onRoster,
    required this.rollStats,
    required this.signedListCount,
    required this.presentToday,
    required this.absentToday,
    required this.liveSessions,
  });

  final bool hasRegistration;
  final bool onRoster;
  final AttendanceRollStats rollStats;
  final int signedListCount;
  final int presentToday;
  final int absentToday;
  final List<AttendanceSession> liveSessions;
}

class _StudentDashboardBody extends StatelessWidget {
  const _StudentDashboardBody({
    required this.student,
    required this.notices,
    required this.formatNoticeTime,
  });

  final _StudentDashViewModel student;
  final List<NoticeRecord> notices;
  final String Function(BuildContext context, NoticeRecord n) formatNoticeTime;

  @override
  Widget build(BuildContext context) {
    if (!student.hasRegistration) {
      return _SectionCard(
        title: 'Get started',
        children: [
          Text(
            'Add your registration number in Settings so the app can match you '
            'to class lists and roll data.',
            style: DashboardCardText.bodySecondary(Theme.of(context).textTheme),
          ),
        ],
      );
    }
    if (!student.onRoster) {
      return _SectionCard(
        title: 'Not on the roster yet',
        children: [
          Text(
            'Your registration is saved, but no student record matches it yet. '
            'Ask your lecturer to add you, or join a class list from Attendance.',
            style: DashboardCardText.bodySecondary(Theme.of(context).textTheme),
          ),
        ],
      );
    }

    final stats = [
      _StatItem(
        'Roll (completed sessions)',
        student.rollStats.total <= 0
            ? '—'
            : '${student.rollStats.percentRounded}%',
        Icons.percent_rounded,
        AppTheme.primary,
      ),
      _StatItem(
        'Your class lists',
        '${student.signedListCount}',
        Icons.bookmark_added_rounded,
        AppTheme.accent,
      ),
      _StatItem(
        'Present today',
        '${student.presentToday}',
        Icons.how_to_reg_rounded,
        AppTheme.success,
      ),
      _StatItem(
        'Absent today',
        '${student.absentToday}',
        Icons.person_off_rounded,
        AppTheme.error,
      ),
      _StatItem(
        'Open check-ins',
        '${student.liveSessions.length}',
        Icons.sensors_rounded,
        AppTheme.accent,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StudentStatsRow(stats: stats),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            if (!wide) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _LiveSessionsCard(sessions: student.liveSessions),
                  const SizedBox(height: 16),
                  _RecentNoticesCard(
                    notices: notices,
                    formatNoticeTime: formatNoticeTime,
                  ),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _LiveSessionsCard(sessions: student.liveSessions),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: _RecentNoticesCard(
                    notices: notices,
                    formatNoticeTime: formatNoticeTime,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _StudentStatsRow extends StatelessWidget {
  const _StudentStatsRow({required this.stats});

  final List<_StatItem> stats;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 600;
        if (isNarrow) {
          return GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: constraints.maxWidth > 320 ? 1.35 : 1.2,
            children: stats.map((s) => _StatCard(item: s)).toList(),
          );
        }
        return Row(
          children: stats
              .map(
                (s) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _StatCard(item: s),
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.children,
    this.trailing,
  });

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.width < 400;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: DashboardCardText.cardTitle(Theme.of(context).textTheme),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            SizedBox(height: compact ? 12 : 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow(this.label, this.value, this.color);

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontSize: DashboardCardText.bodySize,
                  ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: color,
                fontSize: DashboardCardText.captionSize,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
