import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/navigation/app_shell.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/attendance_list_hierarchy.dart';
import '../attendance/attendance_screen.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/models/attendance_models.dart';
import '../attendance/pending_sessions_screen.dart';
import '../notices/data/notices_repository.dart';
import 'dashboard_shared_widgets.dart';

/// Lecturer home: live metrics, tappable actions, and recent notices.
class LecturerDashboardScreen extends StatefulWidget {
  const LecturerDashboardScreen({super.key});

  @override
  State<LecturerDashboardScreen> createState() =>
      _LecturerDashboardScreenState();
}

class _LecturerDashboardScreenState extends State<LecturerDashboardScreen> {
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

  static bool _isSameLocalDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
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
      final raw = await NoticesRepository.instance.fetchRecent(limit: 30);
      final listIds =
          attendanceListsForCurrentStaff().map((l) => l.id).toSet();
      _notices = [
        for (final n in raw)
          if (noticeVisibleToUser(
            n,
            admin: false,
            lecturer: true,
            lecturerListIds: listIds,
            studentId: null,
            signedListIds: const {},
          ))
            n,
      ].take(8).toList();
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

  _LecturerDashMetrics _metrics() {
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

    var activeLists = 0;
    for (final l in attendanceListsForCurrentStaff()) {
      if (l.status == AttendanceListStatus.active) activeLists++;
    }

    final liveSessions =
        AttendanceStore.sessions.where((s) => s.isActive).toList()
          ..sort((a, b) => a.endTime.compareTo(b.endTime));

    return _LecturerDashMetrics(
      presentToday: presentToday,
      absentToday: absentToday,
      activeLists: activeLists,
      liveSessions: liveSessions,
    );
  }

  String _formatNoticeTime(BuildContext context, NoticeRecord n) {
    final loc = MaterialLocalizations.of(context);
    final d = n.scheduledFor ?? n.createdAt;
    return '${loc.formatShortDate(d)} · ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(d))}';
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

  @override
  Widget build(BuildContext context) {
    final auth = AuthRepository.instance;
    final fullName = auth.currentFullName?.trim();
    final staffId = auth.currentStaffNumber?.trim() ?? '—';
    final greeting = (fullName != null && fullName.isNotEmpty)
        ? 'Hello, $fullName'
        : 'Hello, lecturer';

    return ListenableBuilder(
      listenable: Listenable.merge([auth, AppConnectivity.instance]),
      builder: (context, _) {
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
                  title: 'Home',
                  subtitle: 'Staff ID $staffId · Tap any tile to jump in',
                  liveCount: liveCount,
                  lastUpdated: _lastUpdated,
                  refreshing: _loading,
                  onRefresh: () => unawaited(_refresh(forceNetwork: true)),
                ),
                if (offline) ...[
                  const SizedBox(height: 12),
                  _OfflineBanner(),
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
                if (_loading &&
                    !AttendanceRepository.instance.hasCachedStore)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  _LecturerStatsGrid(
                    metrics: m,
                    onLive: () => DashboardShellNav.go(
                      context,
                      AppSection.attendance,
                    ),
                    onLists: () => DashboardShellNav.go(
                      context,
                      AppSection.attendance,
                    ),
                    onPresent: () => DashboardShellNav.go(
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
                    label: 'Open attendance',
                    subtitle: 'Manage lists and start sessions',
                    onTap: () =>
                        DashboardShellNav.go(context, AppSection.attendance),
                  ),
                  const SizedBox(height: 8),
                  DashboardQuickAction(
                    icon: Icons.add_circle_outline_rounded,
                    label: 'Create class list',
                    onTap: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const CreateAttendanceListScreen(),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  DashboardQuickAction(
                    icon: Icons.pending_actions_rounded,
                    label: 'Pending sessions',
                    onTap: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const PendingSessionsScreen(),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  DashboardQuickAction(
                    icon: Icons.campaign_rounded,
                    label: 'Notices',
                    subtitle: 'View announcements for your classes',
                    onTap: () =>
                        DashboardShellNav.go(context, AppSection.notices),
                  ),
                  if (m.liveSessions.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(
                      'Live sessions',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 10),
                    ...m.liveSessions.map((s) {
                      final list = AttendanceStore.listById(s.listId);
                      final title =
                          list?.displayTitle ?? 'Class list ${s.listId}';
                      final mins =
                          s.endTime.difference(DateTime.now()).inMinutes;
                      final ends = mins < 0
                          ? 'ending soon'
                          : '${mins.clamp(0, 9999)} min left';
                      return DashboardTapTile(
                        icon: Icons.sensors_rounded,
                        iconColor: AppTheme.accent,
                        title: title,
                        subtitle:
                            'Code ${normalizeSessionCodeInput(s.sessionCode)} · $ends · Tap to manage',
                        onTap: () => _openSession(context, s),
                      );
                    }),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Text(
                        'Recent notices',
                        style:
                            Theme.of(context).textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () =>
                            DashboardShellNav.go(context, AppSection.notices),
                        child: const Text('See all'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_notices.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'No notices for your classes yet.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    )
                  else
                    ..._notices.map(
                      (n) => DashboardTapTile(
                        icon: Icons.campaign_outlined,
                        title: n.title,
                        subtitle:
                            '${_formatNoticeTime(context, n)} · Tap to read',
                        onTap: () =>
                            DashboardShellNav.go(context, AppSection.notices),
                      ),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LecturerDashMetrics {
  const _LecturerDashMetrics({
    required this.presentToday,
    required this.absentToday,
    required this.activeLists,
    required this.liveSessions,
  });

  final int presentToday;
  final int absentToday;
  final int activeLists;
  final List<AttendanceSession> liveSessions;
}

class _LecturerStatsGrid extends StatelessWidget {
  const _LecturerStatsGrid({
    required this.metrics,
    required this.onLive,
    required this.onLists,
    required this.onPresent,
  });

  final _LecturerDashMetrics metrics;
  final VoidCallback onLive;
  final VoidCallback onLists;
  final VoidCallback onPresent;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cross = 2;
        final aspect = constraints.maxWidth > 520 ? 1.12 : 0.95;
        return GridView.count(
          crossAxisCount: cross,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: aspect,
          children: [
            DashboardStatTile(
              label: 'Live sessions',
              value: '${metrics.liveSessions.length}',
              icon: Icons.sensors_rounded,
              color: AppTheme.accent,
              highlight: metrics.liveSessions.isNotEmpty,
              onTap: onLive,
            ),
            DashboardStatTile(
              label: 'Active lists',
              value: '${metrics.activeLists}',
              icon: Icons.class_rounded,
              color: AppTheme.primary,
              onTap: onLists,
            ),
            DashboardStatTile(
              label: 'Present today',
              value: '${metrics.presentToday}',
              icon: Icons.how_to_reg_rounded,
              color: AppTheme.success,
              onTap: onPresent,
            ),
          ],
        );
      },
    );
  }
}

class _OfflineBanner extends StatelessWidget {
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
              'Pull to refresh when you are back online.',
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
