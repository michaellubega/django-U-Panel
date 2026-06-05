import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/auth/user_role.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/attendance_list_hierarchy.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/models/attendance_models.dart';
import '../notices/create_notice_screen.dart';
import '../notices/data/notices_repository.dart';
import '../attendance/attendance_screen.dart';
import '../settings/staff_admin_hub_screen.dart';
import '../../core/navigation/app_shell.dart';
import 'dashboard_shared_widgets.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = true;
  String? _loadError;
  List<NoticeRecord> _notices = [];
  DateTime? _lastUpdated;

  @override
  void initState() {
    super.initState();
    _loading = !AttendanceRepository.instance.hasCachedStore;
    unawaited(_refresh());
  }

  Future<void> _refresh({bool forceNetwork = false}) async {
    final blocking = !AttendanceRepository.instance.hasCachedStore;
    setState(() {
      _loading = blocking || forceNetwork;
      _loadError = null;
    });
    try {
      await AttendanceRepository.instance.loadAll(
        force: forceNetwork,
        scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
      );
      final raw = await NoticesRepository.instance.fetchRecent(limit: 40);
      final auth = AuthRepository.instance;
      final admin = auth.adminCheckDone && auth.isAdmin;
      final lecturer = auth.lecturerCheckDone && auth.isLecturer && !admin;
      final lecturerListIds = lecturer
          ? attendanceListsForCurrentStaff().map((l) => l.id).toSet()
          : const <String>{};
      final reg = auth.currentRegistrationNumber?.trim();
      final student = reg == null || reg.isEmpty
          ? null
          : AttendanceStore.findStudentByReg(reg);
      final signedListIds = <String>{
        if (student != null)
          ...AttendanceStore.signIns
              .where((s) => s.studentId == student.id)
              .map((s) => s.listId),
      };
      _notices = [
        for (final n in raw)
          if (noticeVisibleToUser(
            n,
            admin: admin,
            lecturer: lecturer,
            lecturerListIds: lecturerListIds,
            studentId: student?.id,
            signedListIds: signedListIds,
          ))
            n,
      ].take(20).toList();
      _lastUpdated = DateTime.now();
      _loadError = null;
    } catch (e) {
      _loadError = '$e';
      _notices = [];
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  void _openSession(BuildContext context, AttendanceSession session) {
    final list = AttendanceStore.listById(session.listId);
    if (list == null) {
      DashboardShellNav.go(context, AppSection.attendance);
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => StartSessionScreen(
          list: list,
          resumeSession: session,
        ),
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
    var presentToday = 0;
    var absentToday = 0;
    for (final r in AttendanceStore.attendanceRecords) {
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

    final now = DateTime.now();
    var presentToday = 0;
    var absentToday = 0;
    for (final r in AttendanceStore.attendanceRecords) {
      if (r.studentId != sid) continue;
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthRepository.instance,
      builder: (context, _) {
        return ListenableBuilder(
          listenable: AppConnectivity.instance,
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

            return RefreshIndicator(
              onRefresh: () => _refresh(forceNetwork: true),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DashboardLiveHeader(
                      title: 'Dashboard',
                      subtitle:
                          'Operational overview — tap tiles and buttons to act',
                      liveCount: liveCount,
                      lastUpdated: _lastUpdated,
                      refreshing: _loading,
                      onRefresh: () => unawaited(_refresh(forceNetwork: true)),
                    ),
                    if (offline) ...[
                      const SizedBox(height: 12),
                      const _OfflineHint(),
                    ],
                    if (_loadError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _loadError!,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: AppTheme.error),
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (_loading && !AttendanceRepository.instance.hasCachedStore)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else ...[
                      _AdminStatsRow(
                        metrics: m,
                        onLive: () => DashboardShellNav.go(
                          context,
                          AppSection.attendance,
                        ),
                        onPresent: () => DashboardShellNav.go(
                          context,
                          AppSection.attendance,
                        ),
                        onAbsent: () => DashboardShellNav.go(
                          context,
                          AppSection.attendance,
                        ),
                        onActiveLists: () => DashboardShellNav.go(
                          context,
                          AppSection.attendance,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Quick actions',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 10),
                      DashboardQuickAction(
                        filled: true,
                        icon: Icons.people_alt_rounded,
                        label: 'Attendance',
                        subtitle: 'All class lists and sessions',
                        onTap: () => DashboardShellNav.go(
                          context,
                          AppSection.attendance,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DashboardQuickAction(
                        icon: Icons.campaign_rounded,
                        label: 'Notices',
                        subtitle: 'View and post announcements',
                        onTap: () => DashboardShellNav.go(
                          context,
                          AppSection.notices,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DashboardQuickAction(
                        icon: Icons.add_circle_outline_rounded,
                        label: 'Create notice',
                        onTap: () {
                          Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => const CreateNoticeScreen(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      DashboardQuickAction(
                        icon: Icons.analytics_rounded,
                        label: 'Reports',
                        subtitle: 'Export attendance data',
                        onTap: () => DashboardShellNav.go(
                          context,
                          AppSection.reports,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const _StaffAdminEntryCard(),
                      const SizedBox(height: 24),
                      _AdminDetailSection(
                        metrics: m,
                        notices: _notices,
                        formatNoticeTime: _formatNoticeTime,
                        onSessionTap: (s) => _openSession(context, s),
                        onSeeNotices: () => DashboardShellNav.go(
                          context,
                          AppSection.notices,
                        ),
                        onSeeAttendance: () => DashboardShellNav.go(
                          context,
                          AppSection.attendance,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
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
    final message = role == UserRole.lecturer
        ? 'Use the Home tab for your lecturer overview.'
        : 'Use Attendance to sign in to class sessions.';
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

class _StaffAdminEntryCard extends StatelessWidget {
  const _StaffAdminEntryCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: AppTheme.primary.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.2)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const StaffAdminHubScreen(),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              const Icon(Icons.groups_rounded, color: AppTheme.primary, size: 28),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Staff & accounts',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Register lecturers, QA admins, and browse staff lists.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                            height: 1.3,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: AppTheme.textSecondary.withValues(alpha: 0.8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminStatsRow extends StatelessWidget {
  const _AdminStatsRow({
    required this.metrics,
    required this.onLive,
    required this.onPresent,
    required this.onAbsent,
    required this.onActiveLists,
  });

  final _DashboardMetrics metrics;
  final VoidCallback onLive;
  final VoidCallback onPresent;
  final VoidCallback onAbsent;
  final VoidCallback onActiveLists;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      DashboardStatTile(
        label: 'Live sessions',
        value: '${metrics.liveSessions.length}',
        icon: Icons.sensors_rounded,
        color: AppTheme.accent,
        highlight: metrics.liveSessions.isNotEmpty,
        onTap: onLive,
      ),
      DashboardStatTile(
        label: 'Present today',
        value: '${metrics.presentToday}',
        icon: Icons.how_to_reg_rounded,
        color: AppTheme.success,
        onTap: onPresent,
      ),
      DashboardStatTile(
        label: 'Absent today',
        value: '${metrics.absentToday}',
        icon: Icons.person_off_rounded,
        color: AppTheme.error,
        onTap: onAbsent,
      ),
      DashboardStatTile(
        label: 'Active class lists',
        value: '${metrics.activeLists}',
        icon: Icons.class_rounded,
        color: AppTheme.primary,
        onTap: onActiveLists,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 700;
        if (isNarrow) {
          return GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            // Taller cells on phones so stat labels do not overflow (was ~1.3).
            childAspectRatio: constraints.maxWidth > 360 ? 1.08 : 0.92,
            children: tiles,
          );
        }
        return SizedBox(
          height: 132,
          child: Row(
            children: tiles
                .map(
                  (t) => Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: t,
                    ),
                  ),
                )
                .toList(),
          ),
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
                        fontSize: 28,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              item.label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
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

class _AdminDetailSection extends StatelessWidget {
  const _AdminDetailSection({
    required this.metrics,
    required this.notices,
    required this.formatNoticeTime,
    required this.onSessionTap,
    required this.onSeeNotices,
    required this.onSeeAttendance,
  });

  final _DashboardMetrics metrics;
  final List<NoticeRecord> notices;
  final String Function(BuildContext context, NoticeRecord n) formatNoticeTime;
  final void Function(AttendanceSession session) onSessionTap;
  final VoidCallback onSeeNotices;
  final VoidCallback onSeeAttendance;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useTwoColumns = constraints.maxWidth >= 900;
        final left = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionCard(
              title: 'Class lists',
              trailing: TextButton(
                onPressed: onSeeAttendance,
                child: const Text('Open attendance'),
              ),
              children: [
                _ListRow('Draft', '${metrics.draftLists}', AppTheme.textSecondary),
                _ListRow('Active', '${metrics.activeLists}', AppTheme.accent),
                _ListRow('Closed', '${metrics.closedLists}', AppTheme.textSecondary),
                _ListRow('Roster students', '${metrics.rosterStudents}', AppTheme.primary),
                _ListRow('List enrollments', '${metrics.listEnrollments}', AppTheme.primary),
              ],
            ),
            if (!useTwoColumns) ...[
              const SizedBox(height: 16),
              _LiveSessionsCard(
                sessions: metrics.liveSessions,
                onSessionTap: onSessionTap,
                onSeeAttendance: onSeeAttendance,
              ),
              const SizedBox(height: 16),
              _RecentNoticesCard(
                notices: notices,
                formatNoticeTime: formatNoticeTime,
                onSeeNotices: onSeeNotices,
              ),
            ],
          ],
        );

        if (!useTwoColumns) return left;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 2, child: left),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _LiveSessionsCard(
                    sessions: metrics.liveSessions,
                    onSessionTap: onSessionTap,
                    onSeeAttendance: onSeeAttendance,
                  ),
                  const SizedBox(height: 16),
                  _RecentNoticesCard(
                    notices: notices,
                    formatNoticeTime: formatNoticeTime,
                    onSeeNotices: onSeeNotices,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LiveSessionsCard extends StatelessWidget {
  const _LiveSessionsCard({
    required this.sessions,
    this.onSessionTap,
    this.onSeeAttendance,
  });

  final List<AttendanceSession> sessions;
  final void Function(AttendanceSession session)? onSessionTap;
  final VoidCallback? onSeeAttendance;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Live check-in sessions',
      trailing: onSeeAttendance == null
          ? null
          : TextButton(
              onPressed: onSeeAttendance,
              child: const Text('Attendance'),
            ),
      children: [
        if (sessions.isEmpty)
          Text(
            'No open sessions right now. Start one from Attendance.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
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
                style: Theme.of(context).textTheme.bodyMedium,
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
            'No notices in Firestore yet.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          )
        else
          ...top.map((n) {
            final aud = n.audience == NoticeAudienceKind.allAppUsers
                ? 'All users'
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
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
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
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
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
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
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
                    style: Theme.of(context).textTheme.titleLarge,
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
              style: Theme.of(context).textTheme.bodyLarge,
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
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
