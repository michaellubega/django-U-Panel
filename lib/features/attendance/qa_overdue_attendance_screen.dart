import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/connectivity/app_connectivity.dart';
import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';
import 'attendance_list_title.dart';
import 'attendance_schedule_utils.dart';
import 'attendance_screen.dart';
import 'data/attendance_repository.dart';
import 'models/attendance_models.dart';

/// QA / admin: classes where the lecturer has not opened attendance 1:30 after
/// the scheduled lesson time — QA can start the session from here.
class QaOverdueAttendanceScreen extends StatefulWidget {
  const QaOverdueAttendanceScreen({super.key});

  @override
  State<QaOverdueAttendanceScreen> createState() =>
      _QaOverdueAttendanceScreenState();
}

class _QaOverdueAttendanceScreenState extends State<QaOverdueAttendanceScreen> {
  bool _loading = true;
  List<AttendanceList> _overdue = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      await AttendanceRepository.instance.loadAll(
        force: !AttendanceRepository.instance.hasCachedStore,
        scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
      );
      if (!mounted) return;
      setState(() {
        _overdue = AttendanceScheduleUtils.overdueListsForQa();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openStartSession(AttendanceList list) {
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute<void>(
            builder: (_) => StartSessionScreen(list: list),
          ),
        )
        .then((_) => unawaited(_reload()));
  }

  String _overdueLabel(AttendanceList list, DateTime now) {
    final scheduled = AttendanceScheduleUtils.scheduledStartOnDate(list, now);
    if (scheduled == null) return 'Scheduled ${list.time}';
    final qaDue = scheduled.add(AttendanceScheduleUtils.qaEscalationAfter);
    final mins = now.difference(qaDue).inMinutes;
    if (mins <= 0) return 'Due for QA action now';
    if (mins < 60) return 'Overdue by $mins min';
    final h = mins ~/ 60;
    final m = mins % 60;
    if (m == 0) return 'Overdue by ${h}h';
    return 'Overdue by ${h}h ${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final offline = !AppConnectivity.instance.isOnline;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Overdue attendance'),
        actions: [
          RefreshIconButton(onRefresh: _reload),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: _loading && _overdue.isEmpty
            ? ListView(
                physics: kRefreshScrollPhysics,
                children: const [
                  SizedBox(height: 120),
                  Center(child: CircularProgressIndicator()),
                ],
              )
            : ListView(
                physics: kRefreshScrollPhysics,
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'These classes were scheduled for today but no attendance session '
                    'was opened within 1 hour 30 minutes. QA can start the session.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  if (offline) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.warning.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        'Offline — list may be incomplete until you reconnect.',
                        style: TextStyle(color: AppTheme.textSecondary),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (_overdue.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 48),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(
                              Icons.check_circle_outline_rounded,
                              size: 48,
                              color: AppTheme.primary.withValues(alpha: 0.7),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No overdue classes right now',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'When a lecturer misses the 1:30 window after lesson time, '
                              'the class will appear here.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    for (final list in _overdue)
                      Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AttendanceListTitleColumn(list: list),
                              const SizedBox(height: 8),
                              Text(
                                list.listLabelLine,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Scheduled ${list.time} · ${_overdueLabel(list, now)}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppTheme.warning,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 14),
                              FilledButton.icon(
                                onPressed: () => _openStartSession(list),
                                icon: const Icon(Icons.play_arrow_rounded),
                                label: const Text('Start session'),
                              ),
                            ],
                          ),
                        ),
                      ),
                ],
              ),
      ),
    );
  }
}
