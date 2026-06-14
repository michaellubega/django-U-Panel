import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/connectivity/app_connectivity.dart';
import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';
import 'data/attendance_offline_sync.dart';
import 'data/attendance_repository.dart';
import 'data/pending_check_in_queue.dart';
import 'data/pending_retention.dart';
import 'data/pending_session_code_queue.dart';
import 'data/pending_session_create_queue.dart';
import 'models/attendance_models.dart';
class PendingSessionsScreen extends StatefulWidget {
  const PendingSessionsScreen({super.key});

  @override
  State<PendingSessionsScreen> createState() => _PendingSessionsScreenState();
}

class _PendingSessionsScreenState extends State<PendingSessionsScreen> {
  bool _loading = true;
  List<PendingSessionCodeEntry> _items = const [];
  List<PendingCheckInEntry> _checkIns = const [];
  List<PendingSessionCreateEntry> _sessionCreates = const [];
  PendingSessionSyncResult? _lastSync;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    AppConnectivity.instance.addListener(_onConnectivityChanged);
    unawaited(_reload(waitForSync: false));
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && !_loading) {
        unawaited(_loadQueuesFromDisk(clearLoading: false));
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    AppConnectivity.instance.removeListener(_onConnectivityChanged);
    super.dispose();
  }

  /// Local queues only — no network drain (instant offline open).
  Future<void> _loadQueuesFromDisk({required bool clearLoading}) async {
    if (clearLoading && mounted) {
      setState(() => _loading = true);
    }
    try {
      final all = await PendingSessionCodeQueue.loadAll();
      final lastSync = await PendingSessionCodeQueue.loadLastSyncResult();
      final checkIns = await PendingCheckInQueue.loadAll();
      final creates = await PendingSessionCreateQueue.loadAll();
      all.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      checkIns.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      if (!mounted) return;
      setState(() {
        _items = all;
        _checkIns = checkIns;
        _sessionCreates = creates;
        _lastSync = lastSync;
        if (clearLoading) _loading = false;
      });
    } catch (_) {
      if (mounted && clearLoading) {
        setState(() => _loading = false);
      }
    }
  }

  /// Upload / purge after UI is visible — must not block first paint.
  Future<void> _runBackgroundSync() async {
    try {
      if (AppConnectivity.instance.isOnline) {
        await AttendanceOfflineSync.drainAllInOrder();
      } else {
        await AttendanceOfflineSync.purgeExpiredPendingOnly();
      }
      await _loadQueuesFromDisk(clearLoading: false);
    } catch (_) {}
  }

  void _onConnectivityChanged() {
    if (!mounted) return;
    unawaited(_loadQueuesFromDisk(clearLoading: false));
    unawaited(_runBackgroundSync());
  }

  /// [waitForSync] true on pull-to-refresh; false on first open (local-first).
  Future<void> _reload({bool waitForSync = true}) async {
    await _loadQueuesFromDisk(clearLoading: true);
    if (waitForSync) {
      await _runBackgroundSync();
    } else {
      unawaited(_runBackgroundSync());
    }
  }

  String _fmt(DateTime d) {
    final local = d.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mi = local.minute.toString().padLeft(2, '0');
    return '$dd/$mm/${local.year} $hh:$mi';
  }

  Color _statusColor(PendingSessionCodeStatus s) {
    switch (s) {
      case PendingSessionCodeStatus.queued:
        return AppTheme.primary;
      case PendingSessionCodeStatus.needsRegistration:
        return AppTheme.warning;
      case PendingSessionCodeStatus.invalidOrExpired:
        return AppTheme.error;
      case PendingSessionCodeStatus.deviceBlocked:
        return AppTheme.error;
    }
  }

  String _statusText(PendingSessionCodeStatus s) {
    switch (s) {
      case PendingSessionCodeStatus.queued:
        return 'Queued';
      case PendingSessionCodeStatus.needsRegistration:
        return 'Needs registration';
      case PendingSessionCodeStatus.invalidOrExpired:
        return 'Session mismatch';
      case PendingSessionCodeStatus.deviceBlocked:
        return 'Another student';
    }
  }

  String _retentionHint(DateTime pendingSince) {
    final days = PendingRetention.daysRemaining(pendingSince, DateTime.now());
    if (days <= 0) {
      return 'Pending verification — will be removed soon (7-day limit).';
    }
    return 'Kept up to $days more day(s) while waiting for session verification.';
  }

  Widget _buildSyncSummaryCard(BuildContext context) {
    final s = _lastSync;
    if (s == null) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Last sync result',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text('Ran at ${_fmt(s.ranAt)}'),
            Text(
              'Started ${s.startedCount} · Remaining ${s.remainingCount} · Auto-submitted ${s.autoSubmittedCount}',
            ),
            Text(
              'Needs registration ${s.needsRegistrationCount} · Invalid marked ${s.invalidMarkedCount} · Invalid removed ${s.invalidRemovedCount}',
            ),
            Text('Device blocked ${s.deviceBlockedCount}'),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingCheckInCard(
      BuildContext context, PendingCheckInEntry e) {
    final sessMap = AttendanceStore.sessionMapById();
    final sid = sessMap[e.sessionId];
    final sessionLabel = sid != null
        ? 'Session code ${normalizeSessionCodeInput(sid.sessionCode)}'
        : 'Session ${e.sessionId}';
    final stud = AttendanceStore.studentMapById()[e.studentId];
    final who = stud != null
        ? '${stud.name} (${stud.registrationNumber})'
        : 'Student id ${e.studentId}';

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
                    'Attendance upload',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'Queued',
                    style: TextStyle(
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(sessionLabel),
            Text(who),
            Text('Course: ${e.course}'),
            Text('Captured: ${_fmt(e.capturedAt)}'),
            Text(
              'Location: ${e.latitude.toStringAsFixed(5)}, ${e.longitude.toStringAsFixed(5)}',
            ),
            const SizedBox(height: 6),
            Text(
              _retentionHint(e.pendingSince),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingSessionCard(
      BuildContext context, PendingSessionCodeEntry e) {
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
                    'Code ${normalizeSessionCodeInput(e.sessionCodeRaw)}',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _statusColor(e.status).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _statusText(e.status),
                    style: TextStyle(
                      color: _statusColor(e.status),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text('Captured: ${_fmt(e.capturedAt)}'),
            Text(
              'Location: ${e.latitude.toStringAsFixed(5)}, ${e.longitude.toStringAsFixed(5)}',
            ),
            Text('Lecturer: ${e.lecturerName ?? 'Pending lookup'}'),
            Text('Class time: ${e.classTime ?? 'Pending lookup'}'),
            Text('Class location: ${e.classLocation ?? 'Pending lookup'}'),
            if (e.status == PendingSessionCodeStatus.queued) ...[
              const SizedBox(height: 6),
              Text(
                _retentionHint(e.pendingSince),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppTheme.textSecondary),
              ),
            ],
            if (e.note != null && e.note!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                e.note!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppTheme.textSecondary),
              ),
            ],
            if (e.status == PendingSessionCodeStatus.needsRegistration) ...[
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: () => _registerAndRetry(e),
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: const Text('Register on list & retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPendingSessionCreateCard(
      BuildContext context, PendingSessionCreateEntry e) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Session publish',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Code ${normalizeSessionCodeInput(e.sessionCode)} · list ${e.listId}',
            ),
            Text('Started: ${_fmt(e.startTime)} · ends ${_fmt(e.endTime)}'),
            Text(
              _retentionHint(e.enqueuedAt),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _pendingListChildren(BuildContext context, bool online) {
    return [
      if (!online)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.warning.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Text(
            'Offline mode: queued work runs when internet is available.',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
        ),
      _buildSyncSummaryCard(context),
      if (_sessionCreates.isNotEmpty) ...[
        Text(
          'Sessions to publish',
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        for (final e in _sessionCreates)
          _buildPendingSessionCreateCard(context, e),
        const SizedBox(height: 12),
      ],
      if (_checkIns.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(
          'Attendance upload queue',
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          'Saved on this device after GPS check; uploads when you are back online.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppTheme.textSecondary, height: 1.35),
        ),
        const SizedBox(height: 8),
        for (final e in _checkIns) _buildPendingCheckInCard(context, e),
        if (_items.isNotEmpty) const SizedBox(height: 12),
      ],
      if (_items.isNotEmpty) ...[
        Text(
          'Session code queue',
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          'Session codes captured when the live session was unclear; validated when online.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppTheme.textSecondary, height: 1.35),
        ),
        const SizedBox(height: 8),
        for (final e in _items) _buildPendingSessionCard(context, e),
      ],
    ];
  }

  Future<void> _registerAndRetry(PendingSessionCodeEntry e) async {
    await AttendanceRepository.instance.loadAll(
      scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
    );
    if (!mounted) return;
    var student = AttendanceStore.findStudentByReg(e.registrationNumber);
    if (student == null) {
      student = await AttendanceRepository.instance
          .registerStudentFromAuthProfile(e.registrationNumber);
      if (!mounted) return;
      if (student == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not load your registered name. Sign in again and retry.',
            ),
          ),
        );
        return;
      }
    }
    if (e.listId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('List info not ready yet. Refresh first.')),
      );
      return;
    }
    final list = AttendanceStore.listById(e.listId!);
    if (list == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Class list not loaded. Pull to refresh.')),
      );
      return;
    }
    String course = AttendanceStore.signedInCourseForStudentOnList(list.id, student.id) ?? '';
    if (course.isEmpty) {
      final picked = await _pickCourse(context, list);
      if (!mounted || picked == null || picked.trim().isEmpty) return;
      course = picked.trim();
      await AttendanceRepository.instance.ensureSignInAndBackfillPastAbsents(
        listId: list.id,
        studentId: student.id,
        course: course,
      );
    }
    await AttendanceOfflineSync.drainAllInOrder();
    await _reload(waitForSync: false);
  }

  Future<String?> _pickCourse(BuildContext context, AttendanceList list) async {
    final courses = list.coursesSafe;
    if (courses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'This class list has no courses on file (${list.whoTaught}). '
            'Ask staff to add courses, then try again.',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
      return null;
    }
    if (courses.length == 1) return courses.first;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final maxHeight = MediaQuery.sizeOf(ctx).height * 0.85;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Choose course',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 12),
                    for (final c in courses)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(ctx).pop(c),
                          child: Text(
                            c,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final online = AppConnectivity.instance.isOnline;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline pending sessions'),
        actions: [
          RefreshIconButton(onRefresh: () => _reload(waitForSync: true)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty && _checkIns.isEmpty && _sessionCreates.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!online) ...[
                          const Text(
                            'Offline: pending work will sync when internet returns.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppTheme.textSecondary),
                          ),
                          const SizedBox(height: 8),
                        ],
                        _buildSyncSummaryCard(context),
                        const SizedBox(height: 8),
                        const Text(
                          'No pending offline session codes or attendance uploads.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => _reload(waitForSync: true),
                  child: ListView(
                    physics: kRefreshScrollPhysics,
                    padding: const EdgeInsets.all(16),
                    children: _pendingListChildren(context, online),
                  ),
                ),
    );
  }
}
