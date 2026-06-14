import 'package:flutter/material.dart';
import 'dart:async';

import '../../core/auth/auth_repository.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/models/attendance_models.dart';
import '../attendance/roll_cell_status.dart';
import '../attendance/attendance_list_hierarchy.dart';
import '../campus_presence/campus_presence_grouping.dart';
import '../campus_presence/data/campus_presence_repository.dart';
import '../lesson_insights/lesson_insights_service.dart';
import '../lesson_insights/lesson_period_filter.dart';
import 'attendance_list_roll.dart';
import 'report_print.dart';
import '../campus_presence/campus_presence_log_screen.dart';
import 'reports_admin_presence_roll_screen.dart';
import 'reports_lecturer_teaching_screen.dart';
import 'reports_attendance_hierarchy.dart';
import 'reports_hub_card.dart';
import '../../core/navigation/app_section.dart';
import '../../core/navigation/screen_refresh.dart';

/// Admin and lecturer reports: browse rolls and print per class list.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, this.shellSection = AppSection.reports});

  final AppSection shellSection;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  bool _busy = false;
  String? _lastRefreshed;
  bool _qaStatsLoading = true;
  int _adminCount = 0;
  int _adminCheckInsThisWeek = 0;
  int _lecturerCount = 0;
  int _lessonsThisWeek = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshAttendance());
      if (AuthRepository.instance.isQaStaff) {
        unawaited(_loadQaHubStats());
      }
    });
  }

  Future<void> _loadQaHubStats() async {
    if (!_isQaStaff) return;
    setState(() => _qaStatsLoading = true);
    try {
      final anchor = DateTime.now();
      final weekRange =
          localDateRangeForPeriod(CampusPresenceLogPeriod.week, anchor);
      final repo = CampusPresenceRepository.instance;
      final roster = await repo.fetchKiuAdminRoster();
      final events = await repo.fetchEventsInLocalDateRange(
        rangeStart: weekRange.start,
        rangeEnd: weekRange.end,
      );
      final grouped = groupEventsIntoDayRows(events);
      final checkIns = grouped.where((r) => r.hasCheckIn).length;

      final lecturerNames = <String>{};
      for (final list in AttendanceStore.lists) {
        if (!attendanceListVisibleInHierarchy(list)) continue;
        final name = LessonInsightsService.lecturerNameForList(list);
        if (name.isNotEmpty) lecturerNames.add(name);
      }

      final pending = await RollPendingContext.load();
      final weekInsights = LessonInsightsService.insightsInPeriod(
        pending,
        filter: LessonPeriodFilter.week,
        anchor: anchor,
      );

      if (!mounted) return;
      setState(() {
        _adminCount = roster.length;
        _adminCheckInsThisWeek = checkIns;
        _lecturerCount = lecturerNames.length;
        _lessonsThisWeek = weekInsights.length;
        _qaStatsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _qaStatsLoading = false);
    }
  }

  bool get _isAdmin =>
      AuthRepository.instance.adminCheckDone && AuthRepository.instance.isAdmin;

  bool get _isQaStaff =>
      AuthRepository.instance.adminCheckDone && AuthRepository.instance.isQaStaff;

  bool get _isLecturer =>
      AuthRepository.instance.lecturerCheckDone &&
      AuthRepository.instance.isLecturer &&
      !_isAdmin;

  bool get _canAccessReports => _isAdmin || _isLecturer;

  Future<void>? _busyFuture;

  Future<void> _withBusy(Future<void> Function() body) async {
    if (_busyFuture != null) return _busyFuture;
    setState(() => _busy = true);
    _busyFuture = body().whenComplete(() {
      if (mounted) setState(() => _busy = false);
      _busyFuture = null;
    });
    return _busyFuture;
  }

  Future<void> _refreshAttendance({bool showSnackBar = true}) async {
    await _withBusy(() async {
      try {
        await AttendanceRepository.instance
            .loadAll(
              force: !AttendanceRepository.instance.hasCachedStore,
              scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
            )
            .timeout(const Duration(seconds: 60));
        if (!mounted) return;
        final t = DateTime.now();
        setState(() {
          _lastRefreshed =
              '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
        });
        if (!mounted || !showSnackBar) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Attendance data refreshed.')),
        );
        unawaited(_loadQaHubStats());
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not refresh: $e')),
        );
      }
    });
  }

  Future<void> _printAllLists(List<AttendanceList> lists) async {
    if (lists.isEmpty) return;
    await _withBusy(() async {
      for (final list in lists) {
        final roll = await buildAttendanceListRoll(list);
        if (roll.students.isEmpty) continue;
        await printAttendanceRollText(
          title: attendanceListRollPrintTitle(roll),
          plainText: buildAttendanceListRollPlainText(roll),
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            lists.length == 1
                ? 'Printed 1 class list.'
                : 'Sent ${lists.length} class lists to print (one dialog per list on web).',
          ),
        ),
      );
    });
  }

  void _openAdminPresenceRoll() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const ReportsAdminPresenceRollScreen(),
      ),
    );
  }

  void _openLecturerTeaching() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const ReportsLecturerTeachingScreen(),
      ),
    );
  }

  void _openCampusPresenceLog() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const CampusPresenceLogScreen(),
      ),
    );
  }

  Widget _buildQaReportsBody(List<AttendanceList> scopedLists) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                'Reports',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            RefreshTonalButton(
              onRefresh: _refreshAttendance,
              busy: _busy,
              label: 'Refresh',
            ),
          ],
        ),
        if (_lastRefreshed != null) ...[
          const SizedBox(height: 4),
          Text(
            'Updated $_lastRefreshed',
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: 16),
        ReportsHubCard(
          title: 'KIU administrators',
          subtitle:
              'Campus arrivals, departures, late check-ins, and overwork by date.',
          icon: Icons.badge_rounded,
          accentColor: AppTheme.primary,
          gradientEnd: AppTheme.accentLight,
          stats: [
            ReportsHubStat(
              icon: Icons.groups_rounded,
              label: _qaStatsLoading ? 'Loading…' : '$_adminCount admins',
              loading: _qaStatsLoading,
            ),
            ReportsHubStat(
              icon: Icons.login_rounded,
              label: _qaStatsLoading
                  ? 'This week'
                  : '$_adminCheckInsThisWeek check-ins this week',
              color: AppTheme.success,
              loading: _qaStatsLoading,
            ),
          ],
          onTap: _openAdminPresenceRoll,
        ),
        ReportsHubCard(
          title: 'Lecturers',
          subtitle:
              'Teaching dates, classes taught, rooms, and session duration.',
          icon: Icons.school_rounded,
          accentColor: AppTheme.secondary,
          gradientEnd: AppTheme.primaryLight.withValues(alpha: 0.25),
          stats: [
            ReportsHubStat(
              icon: Icons.person_rounded,
              label: _qaStatsLoading ? 'Loading…' : '$_lecturerCount lecturers',
              loading: _qaStatsLoading,
            ),
            ReportsHubStat(
              icon: Icons.menu_book_rounded,
              label: _qaStatsLoading
                  ? 'This week'
                  : '$_lessonsThisWeek lessons this week',
              color: AppTheme.primary,
              loading: _qaStatsLoading,
            ),
          ],
          onTap: _openLecturerTeaching,
        ),
        if (scopedLists.isEmpty)
          Text(
            'No attendance lists in the system yet.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppTheme.textSecondary,
            ),
          )
        else
          _BrowseSection(
            lists: scopedLists,
            title: 'Attendance rolls',
            subtitle:
                'Class day → Program → Year → Semester → Class. Open any list to see present and absent members, then print.',
          ),
      ],
    );
  }

  Widget _buildStandardReportsHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Reports',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _isAdmin
                    ? 'Browse attendance by class day, then program — weekend only on Saturday and Sunday.'
                    : 'Your linked lists by class day and program — weekend only Sat–Sun.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (_lastRefreshed != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Last refresh: $_lastRefreshed',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                ),
              ],
            ],
          ),
        ),
        RefreshTonalButton(
          onRefresh: _refreshAttendance,
          busy: _busy,
          label: 'Refresh data',
        ),
      ],
    );
  }

  Widget _buildStandardReportsBody(List<AttendanceList> scopedLists) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isAdmin && !_isQaStaff) ...[
          OutlinedButton.icon(
            onPressed: _openCampusPresenceLog,
            icon: const Icon(Icons.place_rounded, size: 18),
            label: const Text('Campus presence log'),
          ),
          const SizedBox(height: 16),
        ],
        if (scopedLists.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : () => _printAllLists(scopedLists),
              icon: const Icon(Icons.print_rounded, size: 18),
              label: Text(
                _isLecturer ? 'Print all my lists' : 'Print all lists',
              ),
            ),
          ),
        if (scopedLists.isEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _isLecturer
                ? 'No attendance lists are linked to your account yet. Ask QA to assign you on each list (lecturer field).'
                : 'No attendance lists in the system yet.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
        ] else ...[
          const SizedBox(height: 12),
          _BrowseSection(
            lists: scopedLists,
            title: _isLecturer ? 'My class lists' : 'Browse attendance',
            subtitle: _isLecturer
                ? 'Only lists linked to your lecturer account — open any class to see present/absent members and print.'
                : 'Class day → Program → Year → Semester → Class — open any list to see present/absent members and print.',
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthRepository.instance;
    if (!auth.adminCheckDone || !auth.lecturerCheckDone) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_canAccessReports) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline_rounded,
                      size: 40, color: AppTheme.textSecondary),
                  const SizedBox(height: 16),
                  Text('Staff only',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    'Reports are available to lecturers and QA admins.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final scopedLists = attendanceListsForCurrentStaff();
    final qaLayout = _isQaStaff;

    return ScreenRefreshRegistrar(
      section: widget.shellSection,
      onRefresh: _refreshAttendance,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!qaLayout) ...[
            _buildStandardReportsHeader(),
            const SizedBox(height: 20),
          ],
          Expanded(
            child: PullToRefreshScrollable(
              onRefresh: _refreshAttendance,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: qaLayout
                    ? _buildQaReportsBody(scopedLists)
                    : _buildStandardReportsBody(scopedLists),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowseSection extends StatelessWidget {
  const _BrowseSection({
    required this.lists,
    required this.title,
    required this.subtitle,
  });

  final List<AttendanceList> lists;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.background,
            AppTheme.accentLight.withValues(alpha: 0.35),
          ],
        ),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.account_tree_rounded,
                  color: AppTheme.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ReportsDayHubSection(lists: lists),
        ],
      ),
    );
  }
}
