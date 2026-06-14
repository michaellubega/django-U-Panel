import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/debounced_callback.dart';
import '../../core/widgets/content_skeleton.dart';
import '../attendance/attendance_list_title.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/models/attendance_models.dart';
import '../attendance/student_attendance_live_sync.dart';
import '../attendance/student_session_grace.dart';
import '../attendance/roll_cell_status.dart';

/// Per-session attendance for one class list (opened from Profile).
class StudentClassAttendanceDetailScreen extends StatefulWidget {
  const StudentClassAttendanceDetailScreen({
    super.key,
    required this.listId,
    required this.listTitle,
    required this.listSubtitle,
  });

  final String listId;
  final String listTitle;
  final String listSubtitle;

  @override
  State<StudentClassAttendanceDetailScreen> createState() =>
      _StudentClassAttendanceDetailScreenState();
}

class _StudentClassAttendanceDetailScreenState
    extends State<StudentClassAttendanceDetailScreen> {
  bool _loading = false;
  Map<String, String> _rejectionBySession = {};
  RollPendingContext _pending = const RollPendingContext.empty();
  String? _studentId;
  Set<String> _studentIds = const {};
  late final DebouncedCallback _storeRebuild = DebouncedCallback(
    delay: const Duration(milliseconds: 180),
    callback: () {
      if (!mounted) return;
      unawaited(_reloadFromStore());
    },
  );

  @override
  void initState() {
    super.initState();
    AttendanceRepository.instance.addListener(_onStore);
    _resolveStudentId();
    _syncFromStore();
    unawaited(
      StudentAttendanceLiveSync.activate(prioritizeListId: widget.listId),
    );
    unawaited(_warmThenRefresh());
  }

  @override
  void dispose() {
    AttendanceRepository.instance.removeListener(_onStore);
    _storeRebuild.dispose();
    super.dispose();
  }

  void _onStore() {
    _storeRebuild.schedule();
  }

  Future<void> _reloadFromStore() async {
    _syncFromStore();
    _pending = await RollPendingContext.load();
    if (!mounted) return;
    setState(() {});
  }

  void _resolveStudentId() {
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg == null || reg.isEmpty) {
      _studentId = null;
      _studentIds = const {};
      return;
    }
    _studentIds = AttendanceStore.studentIdsForRegistrationNormalized(reg);
    _studentId = AttendanceStore.findStudentByReg(reg)?.id ??
        (_studentIds.length == 1 ? _studentIds.first : null);
  }

  bool _anyStudentHasPendingPresent(String sessionId) {
    for (final sid in _studentIds) {
      if (_pending.studentHasPendingPresent(sessionId, sid)) return true;
    }
    return false;
  }

  void _syncFromStore() {
    _resolveStudentId();
    final repo = AttendanceRepository.instance;
    final sessions = AttendanceStore.sessionsForListNewestFirst(widget.listId);
    final hasRows = repo.listDetailReady(widget.listId) || sessions.isNotEmpty;
    if (!mounted) return;
    setState(() {
      if (hasRows || !AppConnectivity.instance.isOnline) {
        _loading = false;
      }
    });
  }

  Future<void> _warmThenRefresh() async {
    await AttendanceRepository.instance.warmFromLocalSnapshot();
    if (!mounted) return;
    _syncFromStore();

    await AttendanceRepository.instance.refreshStudentListAttendanceFromRtd(
      widget.listId,
    );
    if (!mounted) return;
    _syncFromStore();

    if (!AppConnectivity.instance.isOnline) {
      await AttendanceRepository.instance.loadStudentAttendanceForProfile(
        force: false,
      );
      if (!mounted) return;
      _syncFromStore();
      _pending = await RollPendingContext.load();
      if (mounted) setState(() => _loading = false);
      return;
    }

    unawaited(() async {
      await AttendanceRepository.instance.loadStudentAttendanceForProfile(
        force: false,
      );
      if (!mounted) return;
      _syncFromStore();
      await _refresh(force: false);
    }());
  }

  Future<void> _refresh({required bool force}) async {
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg == null || reg.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    if (AppConnectivity.instance.isOnline) {
      await AttendanceRepository.instance.refreshStudentListAttendanceFromRtd(
        widget.listId,
      );
    }
    _syncFromStore();

    if (!force && AttendanceRepository.instance.hasCachedStore) {
      unawaited(
        AttendanceRepository.instance.loadStudentAttendanceForProfile(
          force: false,
        ),
      );
    } else {
      await AttendanceRepository.instance.loadStudentAttendanceForProfile(
        force: force && AppConnectivity.instance.isOnline,
      );
    }
    _syncFromStore();

    if (!AppConnectivity.instance.isOnline && !force) {
      _pending = await RollPendingContext.load();
      if (mounted) setState(() => _loading = false);
      return;
    }

    final hasLocal =
        AttendanceRepository.instance.hasLocalListData(widget.listId);
    if (!hasLocal && mounted) {
      setState(() => _loading = true);
    }

    if (!force && hasLocal) {
      await _finishRefreshAfterListLoad();
      unawaited(
        AttendanceRepository.instance
            .loadListAttendanceData(widget.listId, force: false)
            .then((_) async {
          if (!mounted) return;
          await _finishRefreshAfterListLoad();
        }),
      );
      return;
    }

    await AttendanceRepository.instance.loadListAttendanceData(
      widget.listId,
      force: force,
    );
    await _finishRefreshAfterListLoad();
  }

  Future<void> _finishRefreshAfterListLoad() async {
    _resolveStudentId();

    if (_studentId != null) {
      _rejectionBySession = await AttendanceRepository.instance
          .fetchCheckInAttemptRejectionBySession(
        listId: widget.listId,
        studentId: _studentId!,
      );
    }
    _pending = await RollPendingContext.load();

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  String _formatDateTime(DateTime dt) {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final w = wd[dt.weekday - 1];
    final m = mo[dt.month - 1];
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$w ${dt.day} $m ${dt.year} · $h:$min';
  }

  String _sessionWhen(AttendanceSession s) => _formatDateTime(s.startTime);

  String _commentFor({
    required AttendanceSession session,
    required AttendanceRecord? record,
    required String? label,
    required String? rejection,
    required DateTime? enrolledAt,
  }) {
    if (label == kRollLabelPresent) {
      if (record != null) {
        final when = _formatDateTime(record.timestamp);
        if (record.verified) {
          return 'Present — verified check-in at $when.';
        }
        return 'Present — check-in recorded at $when.';
      }
      return 'Present for this session.';
    }

    if (label == kRollLabelPending) {
      if (_anyStudentHasPendingPresent(session.id)) {
        return 'Check-in saved on this device — waiting to upload and verify.';
      }
      if (_pending.sessionAwaitingUpload(session.id) ||
          _pending.sessionMetadataIncomplete(session.id)) {
        return 'Waiting for lecturer session details to finish syncing.';
      }
      return 'Attendance verification in progress.';
    }

    if (rejection != null && rejection.isNotEmpty) {
      return 'Check-in declined: $rejection';
    }

    final missedBeforeJoin =
        enrolledAt != null && session.endTime.isBefore(enrolledAt);
    if (missedBeforeJoin) {
      return 'Missed — session ended before you joined this class list.';
    }

    if (label == kRollLabelAbsent) {
      return 'Absent — no check-in recorded for this session.';
    }

    if (!registrationSessionGraceExpired(
      session: session,
      listId: widget.listId,
      studentIds: _studentIds,
      recordsForStudents: AttendanceStore.attendanceRecords
          .where((r) => _studentIds.contains(r.studentId)),
    )) {
      return 'No check-in recorded yet for this session.';
    }

    return 'Absent — no check-in recorded for this session.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = AttendanceStore.listById(widget.listId);
    final sessions = AttendanceStore.sessionsForListNewestFirst(widget.listId)
        .where((s) => s.countsTowardRollStats)
        .toList();
    DateTime? enrolledAt;
    if (_studentIds.isNotEmpty) {
      for (final sid in _studentIds) {
        final at = AttendanceStore.earliestSignInAtForStudentOnList(
          widget.listId,
          sid,
        );
        if (at == null) continue;
        if (enrolledAt == null || at.isBefore(enrolledAt)) {
          enrolledAt = at;
        }
      }
    }
    final records = _studentIds.isEmpty
        ? const <AttendanceRecord>[]
        : AttendanceStore.attendanceRecords
            .where((r) => _studentIds.contains(r.studentId))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance records'),
        actions: [
          RefreshIconButton(onRefresh: () => _refresh(force: true)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(force: true),
        child: _loading
            ? ListView(
                physics: kRefreshScrollPhysics,
                children: const [
                  SizedBox(height: 120),
                  Center(child: ContentSkeleton(rows: 4)),
                ],
              )
            : ListView(
                physics: kRefreshScrollPhysics,
                padding: const EdgeInsets.all(16),
                children: [
                  AttendanceListTitleStringsColumn(
                    title: widget.listTitle,
                    subtitle: widget.listSubtitle,
                  ),
                  if (list != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      list.listLabelLine,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (sessions.isEmpty)
                    Text(
                      'No completed sessions on this list yet.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    )
                  else
                    ...sessions.map((session) {
                      final record = mergedRollRecordForSession(
                        session: session,
                        studentIds: _studentIds,
                        recordsForStudents: records,
                      );
                      final labelSid = _studentId ??
                          (_studentIds.length == 1 ? _studentIds.first : null);
                      String? label;
                      if (record != null && record.present) {
                        label = kRollLabelPresent;
                      } else if (record != null &&
                          !record.present &&
                          session.countsTowardRollStats) {
                        label = kRollLabelAbsent;
                      } else if (labelSid != null) {
                        label = rollCellLabelForStudentSession(
                          session: session,
                          studentId: labelSid,
                          recordsForStudent: records,
                          pending: _pending,
                        );
                      }
                      final comment = _commentFor(
                        session: session,
                        record: record,
                        label: label,
                        rejection: _rejectionBySession[session.id],
                        enrolledAt: enrolledAt,
                      );
                      final statusColor = switch (label) {
                        kRollLabelPresent => AppTheme.success,
                        kRollLabelAbsent => AppTheme.error,
                        kRollLabelPending => AppTheme.warning,
                        _ => AppTheme.textSecondary,
                      };

                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _sessionWhen(session),
                                      style:
                                          theme.textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  if (label != null)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: statusColor.withValues(
                                          alpha: 0.12,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        label,
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                          color: statusColor,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              if (!session.remoteLearning)
                                Text(
                                  'Code ${normalizeSessionCodeInput(session.sessionCode)}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                              if (!session.remoteLearning)
                                const SizedBox(height: 10),
                              if (session.remoteLearning)
                                const SizedBox(height: 4),
                              Text(
                                comment,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),
      ),
    );
  }
}
