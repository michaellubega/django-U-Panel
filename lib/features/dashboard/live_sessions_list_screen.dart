import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/navigation/app_navigator.dart';
import '../../core/navigation/screen_refresh.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/auth/user_role.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/debounced_callback.dart';
import '../attendance/attendance_list_hierarchy.dart';
import '../attendance/attendance_screen.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/data/attendance_remote_record_watch.dart';
import '../attendance/data/attendance_rtd_record_watch.dart';
import '../attendance/models/attendance_models.dart';
import '../attendance/roll_cell_status.dart';

/// All currently active check-in sessions (newest ending first).
List<AttendanceSession> collectLiveSessions({bool scopeToStaffLists = false}) {
  var sessions = AttendanceStore.sessions.where((s) => s.isActive);
  if (scopeToStaffLists) {
    final listIds = attendanceListsForCurrentStaff().map((l) => l.id).toSet();
    sessions = sessions.where((s) => listIds.contains(s.listId));
  }
  return sessions.toList()..sort((a, b) => a.endTime.compareTo(b.endTime));
}

String _formatSessionTime(BuildContext context, DateTime dt) {
  final loc = MaterialLocalizations.of(context);
  return '${loc.formatShortDate(dt)} · '
      '${loc.formatTimeOfDay(TimeOfDay.fromDateTime(dt))}';
}

String _timeRemainingLabel(DateTime endTime) {
  final mins = endTime.difference(DateTime.now()).inMinutes;
  if (mins < 0) return 'Ending now';
  if (mins == 0) return 'Less than 1 min left';
  if (mins < 60) return '$mins min left';
  final h = mins ~/ 60;
  final m = mins % 60;
  if (m == 0) return '$h h left';
  return '$h h $m min left';
}

/// Full-screen list of running live check-in sessions and their details.
class LiveSessionsListScreen extends StatefulWidget {
  const LiveSessionsListScreen({
    super.key,
    this.scopeToStaffLists = false,
    this.onSessionTap,
  });

  /// When true, only sessions for [attendanceListsForCurrentStaff] are shown.
  final bool scopeToStaffLists;

  final void Function(AttendanceSession session)? onSessionTap;

  @override
  State<LiveSessionsListScreen> createState() => _LiveSessionsListScreenState();
}

class _LiveSessionsListScreenState extends State<LiveSessionsListScreen> {
  Timer? _ticker;
  RollPendingContext _rollPending = const RollPendingContext.empty();
  final Set<String> _watchedSessionIds = {};
  late final DebouncedCallback _pendingReload = DebouncedCallback(
    delay: const Duration(milliseconds: 60),
    callback: () => unawaited(_reloadRollPending()),
  );

  @override
  void initState() {
    super.initState();
    AttendanceRepository.instance.addListener(_onStoreChanged);
    unawaited(_reloadRollPending());
    _syncSessionsFromStore();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    AttendanceRepository.instance.removeListener(_onStoreChanged);
    _pendingReload.dispose();
    _ticker?.cancel();
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    _syncSessionsFromStore();
    _pendingReload.schedule();
  }

  Future<void> _reloadRollPending() async {
    final pending = await RollPendingContext.load();
    if (!mounted) return;
    setState(() => _rollPending = pending);
  }

  void _ensureWatchingSessions(List<AttendanceSession> sessions) {
    final activeIds = sessions.map((s) => s.id).toSet();
    for (final id in activeIds) {
      if (!_watchedSessionIds.add(id)) continue;
      unawaited(
        AttendanceRemoteRecordWatch.instance.watchActiveSessionRecords(id),
      );
      unawaited(
        AttendanceRtdRecordWatch.instance.watchActiveSessionRecords(id),
      );
    }
    _watchedSessionIds.removeWhere((id) => !activeIds.contains(id));
  }

  void _syncSessionsFromStore() {
    final sessions = collectLiveSessions(
      scopeToStaffLists: widget.scopeToStaffLists,
    );
    _ensureWatchingSessions(sessions);
    if (mounted) setState(() {});
  }

  void _defaultOpenSession(AttendanceSession session) {
    final list = AttendanceStore.listById(session.listId);
    if (list == null) return;
    pushAppPage<void>(
      context,
      StartSessionScreen(
        list: list,
        resumeSession: session,
      ),
    );
  }

  Future<void> _refresh() async {
    await AttendanceRepository.instance.warmFromLocalSnapshot();
    unawaited(
      AttendanceRepository.instance.bootstrapLoadIfNeeded(force: true),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final canManage = AuthRepository.instance.resolvedRole.hasStaffOperationalAccess ||
        AuthRepository.instance.isLecturer;

    return ListenableBuilder(
      listenable: AttendanceRepository.instance,
      builder: (context, _) {
        final sessions = collectLiveSessions(
          scopeToStaffLists: widget.scopeToStaffLists,
        );

        return Scaffold(
          appBar: AppBar(
            title: const Text('Live sessions'),
            actions: [
              if (showToolbarRefreshButtons(context))
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: () => unawaited(_refresh()),
                  icon: const Icon(Icons.refresh_rounded),
                ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: _refresh,
            child: sessions.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(24),
                    children: [
                      const SizedBox(height: 48),
                      Icon(
                        Icons.sensors_rounded,
                        size: 56,
                        color: AppTheme.textSecondary.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No live sessions',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'When a lecturer starts check-in, the session will appear here '
                        'with the join code and class details.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: AppTheme.textSecondary,
                              height: 1.45,
                            ),
                      ),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: sessions.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final session = sessions[index];
                      return _LiveSessionDetailCard(
                        session: session,
                        rollPending: _rollPending,
                        canOpen: canManage,
                        onTap: canManage
                            ? () {
                                final tap = widget.onSessionTap;
                                if (tap != null) {
                                  tap(session);
                                } else {
                                  _defaultOpenSession(session);
                                }
                              }
                            : null,
                      );
                    },
                  ),
          ),
        );
      },
    );
  }
}

class _LiveSessionDetailCard extends StatelessWidget {
  const _LiveSessionDetailCard({
    required this.session,
    required this.rollPending,
    required this.canOpen,
    this.onTap,
  });

  final AttendanceSession session;
  final RollPendingContext rollPending;
  final bool canOpen;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final list = AttendanceStore.listById(session.listId);
    final title = list?.displayTitle ?? 'Class list ${session.listId}';
    final subtitle = list?.displaySubtitle ?? '';
    final code = normalizeSessionCodeInput(session.sessionCode);
    final uptake = list != null
        ? liveSessionCheckInSnapshot(
            session: session,
            list: list,
            pending: rollPending,
          )
        : LiveSessionCheckInSnapshot.empty;
    final theme = Theme.of(context);

    final details = <_DetailRow>[
      _DetailRow(
        Icons.tag_rounded,
        'Join code',
        code,
        emphasize: true,
      ),
      _DetailRow(
        Icons.timer_outlined,
        'Time left',
        _timeRemainingLabel(session.endTime),
      ),
      _DetailRow(
        Icons.play_circle_outline_rounded,
        'Started',
        _formatSessionTime(context, session.startTime),
      ),
      _DetailRow(
        Icons.stop_circle_outlined,
        'Ends',
        _formatSessionTime(context, session.endTime),
      ),
      _DetailRow(
        Icons.how_to_reg_rounded,
        'Checked in',
        uptake.enrolled > 0
            ? '${uptake.percentCheckedIn}% · ${uptake.subtitle}'
            : '${uptake.present} present',
      ),
      _DetailRow(
        Icons.place_outlined,
        'Mode',
        session.remoteLearning
            ? 'Remote learning (no GPS radius)'
            : 'On campus · ${session.radiusMeters.round()} m radius',
      ),
    ];

    if (list != null) {
      details.insert(
        1,
        _DetailRow(
          Icons.schedule_rounded,
          'Class time',
          '${list.listLabelLine} · ${list.time}',
        ),
      );
      if (list.room.trim().isNotEmpty) {
        details.insert(
          2,
          _DetailRow(Icons.meeting_room_outlined, 'Room', list.room.trim()),
        );
      }
    }

    final child = Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppTheme.accent.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.sensors_rounded,
                    color: AppTheme.accent,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.accent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'LIVE',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _timeRemainingLabel(session.endTime),
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: AppTheme.accent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...details.map((d) => _DetailLine(row: d)),
            if (canOpen && onTap != null) ...[
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onTap,
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Open session'),
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (onTap == null) return child;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: child,
      ),
    );
  }
}

class _DetailRow {
  const _DetailRow(
    this.icon,
    this.label,
    this.value, {
    this.emphasize = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool emphasize;
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.row});

  final _DetailRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(row.icon, size: 18, color: AppTheme.textSecondary),
          const SizedBox(width: 10),
          SizedBox(
            width: 88,
            child: Text(
              row.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              row.value,
              style: row.emphasize
                  ? theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: AppTheme.primary,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
