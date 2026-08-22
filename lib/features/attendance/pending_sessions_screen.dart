import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
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
  bool _reconciling = false;
  List<PendingSessionCodeEntry> _items = const [];
  List<PendingCheckInEntry> _checkIns = const [];
  List<PendingSessionCreateEntry> _sessionCreates = const [];
  PendingSessionSyncResult? _lastSync;
  Timer? _pollTimer;
  Set<String> _uploadedEntryIds = {};

  @override
  void initState() {
    super.initState();
    AppConnectivity.instance.addListener(_onConnectivityChanged);
    unawaited(_reload(waitForSync: false));
    _pollTimer = Timer.periodic(const Duration(seconds: 8), (_) {
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

  /// Local queues only — instant paint; no network on this path.
  Future<void> _loadQueuesFromDisk({required bool clearLoading}) async {
    if (clearLoading && mounted) {
      setState(() => _loading = true);
    }
    try {
      final all = await PendingSessionCodeQueue.loadAll();
      final lastSync = await PendingSessionCodeQueue.loadLastSyncResult();
      final checkIns = _mergeCheckInsFromStore(await PendingCheckInQueue.loadAll());
      final creates = await PendingSessionCreateQueue.loadAll();
      all.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      checkIns.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      creates.sort((a, b) => b.enqueuedAt.compareTo(a.enqueuedAt));
      if (!mounted) return;
      final diskFlags = _uploadFlagsFromDisk(checkIns: checkIns, codes: all);
      diskFlags.addAll(_uploadedEntryIds);
      setState(() {
        _items = all;
        _checkIns = checkIns;
        _sessionCreates = creates;
        _lastSync = lastSync;
        if (clearLoading) _loading = false;
        _uploadedEntryIds = diskFlags;
      });
      unawaited(_refreshUploadFlags());
    } catch (_) {
      if (mounted && clearLoading) {
        setState(() => _loading = false);
      }
    }
  }

  /// Backfill + status reconcile — runs after first paint or on pull-to-refresh.
  Future<void> _reconcileQueuesInBackground() async {
    if (_reconciling) return;
    _reconciling = true;
    try {
      final repo = AttendanceRepository.instance;
      await repo.recoverUnqueuedLocalPresentCheckIns(resolveOnline: false);
      if (AppConnectivity.instance.hasNetworkInterface) {
        await repo.recoverUnqueuedLocalPresentCheckIns();
        await repo.reconcilePendingCheckInQueueStatuses();
      }
      if (!mounted) return;
      final checkIns =
          _mergeCheckInsFromStore(await PendingCheckInQueue.loadAll());
      checkIns.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      setState(() => _checkIns = checkIns);
      await _refreshUploadFlags();
    } catch (_) {
    } finally {
      _reconciling = false;
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

  Set<String> _uploadFlagsFromDisk({
    required List<PendingCheckInEntry> checkIns,
    required List<PendingSessionCodeEntry> codes,
  }) {
    final uploaded = <String>{};
    for (final e in checkIns) {
      if (e.hasLocalUploadEvidence) uploaded.add(e.id);
    }
    for (final e in codes) {
      if (e.hasLocalUploadEvidence) uploaded.add(e.id);
    }
    return uploaded;
  }

  Future<void> _refreshUploadFlags() async {
    final uploaded = _uploadFlagsFromDisk(checkIns: _checkIns, codes: _items);
    uploaded.addAll(_uploadedEntryIds);
    if (!AppConnectivity.instance.hasNetworkInterface) {
      if (!mounted) return;
      setState(() => _uploadedEntryIds = uploaded);
      return;
    }
    final repo = AttendanceRepository.instance;
    final newlyConfirmed = <String>[];

    for (final e in _checkIns) {
      if (uploaded.contains(e.id)) continue;
      final session = AttendanceStore.sessionById(e.sessionId);
      if (await repo.pendingCheckInHasServerEvidence(
        entry: e,
        session: session,
      )) {
        uploaded.add(e.id);
        newlyConfirmed.add(e.id);
      }
    }

    for (final e in _items) {
      if (uploaded.contains(e.id)) continue;
      final student = AttendanceStore.findStudentByReg(e.registrationNumber);
      if (student == null) continue;
      final session = e.sessionId != null
          ? AttendanceStore.sessionById(e.sessionId!)
          : null;
      if (await repo.pendingSessionCodeHasServerEvidence(
        entry: e,
        studentId: student.id,
        session: session,
      )) {
        uploaded.add(e.id);
        newlyConfirmed.add(e.id);
      }
    }

    for (final id in newlyConfirmed) {
      if (_checkIns.any((e) => e.id == id)) {
        await PendingCheckInQueue.markUploaded(id);
      } else if (_items.any((e) => e.id == id)) {
        await PendingSessionCodeQueue.markUploaded(id);
      }
    }

    if (!mounted) return;
    setState(() => _uploadedEntryIds = uploaded);
  }

  void _onConnectivityChanged() {
    if (!mounted) return;
    unawaited(_loadQueuesFromDisk(clearLoading: false));
    unawaited(_runBackgroundSync());
  }

  /// [waitForSync] true on pull-to-refresh; false on first open (local-first).
  Future<void> _reload({bool waitForSync = true}) async {
    await _loadQueuesFromDisk(clearLoading: true);
    unawaited(_reconcileQueuesInBackground());
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
      case PendingSessionCodeStatus.approved:
        return AppTheme.success;
      case PendingSessionCodeStatus.needsRegistration:
        return AppTheme.warning;
      case PendingSessionCodeStatus.invalidOrExpired:
        return AppTheme.error;
      case PendingSessionCodeStatus.deviceBlocked:
        return AppTheme.error;
      case PendingSessionCodeStatus.uploadFailed:
        return AppTheme.error;
    }
  }

  Color _checkInQueueStatusColor(PendingCheckInQueueStatus s) {
    switch (s) {
      case PendingCheckInQueueStatus.queued:
        return AppTheme.primary;
      case PendingCheckInQueueStatus.approved:
        return AppTheme.success;
    }
  }

  String _statusText(PendingSessionCodeEntry e) {
    switch (e.status) {
      case PendingSessionCodeStatus.queued:
        return e.hasLocalUploadEvidence
            ? 'Waiting for lecturer session'
            : 'Saving — uploading…';
      case PendingSessionCodeStatus.approved:
        return 'Confirmed present ✓';
      case PendingSessionCodeStatus.needsRegistration:
        return 'Reg. number not found — check your profile';
      case PendingSessionCodeStatus.invalidOrExpired:
        return 'Outside session bounds';
      case PendingSessionCodeStatus.deviceBlocked:
        return 'Device already used by another student';
      case PendingSessionCodeStatus.uploadFailed:
        return 'Upload failed — will retry automatically';
    }
  }

  String _checkInQueueStatusText(PendingCheckInQueueStatus s) {
    switch (s) {
      case PendingCheckInQueueStatus.queued:
        return 'Saved — uploading…';
      case PendingCheckInQueueStatus.approved:
        return 'Confirmed present ✓';
    }
  }

  String _retentionHint(DateTime pendingSince) {
    final days = PendingRetention.daysRemaining(pendingSince, DateTime.now());
    if (days <= 0) {
      return 'Seven-day retention ended — will be removed soon.';
    }
    return 'Kept for $days more day(s) (7-day retention).';
  }

  /// Shows recent local present rows that were not yet written to the queue file.
  List<PendingCheckInEntry> _mergeCheckInsFromStore(
    List<PendingCheckInEntry> queued,
  ) {
    final reg =
        AuthRepository.instance.currentRegistrationNumber?.trim() ?? '';
    if (reg.isEmpty) return queued;
    final studentIds = AttendanceStore.studentIdsForRegistrationNormalized(reg);
    if (studentIds.isEmpty) return queued;
    final queuedIds = queued.map((e) => e.id).toSet();
    final now = DateTime.now();
    final merged = List<PendingCheckInEntry>.from(queued);
    for (final row in AttendanceStore.attendanceRecords) {
      if (!studentIds.contains(row.studentId)) continue;
      if (!row.present) continue;
      if (!PendingRetention.isWithinRetention(row.timestamp, now)) continue;
      if (queuedIds.contains(row.id)) continue;
      final session = AttendanceStore.sessionById(row.sessionId);
      final listId = session?.listId ?? '';
      merged.add(
        PendingCheckInEntry(
          id: row.id,
          sessionId: row.sessionId,
          studentId: row.studentId,
          listId: listId,
          course: row.course,
          capturedAt: row.timestamp,
          latitude: row.latitude,
          longitude: row.longitude,
          deviceId: row.deviceId?.trim() ?? '',
          pendingSince: row.timestamp,
          status: row.verified
              ? PendingCheckInQueueStatus.approved
              : PendingCheckInQueueStatus.queued,
          sessionCodeRaw: session != null
              ? normalizeSessionCodeInput(session.sessionCode)
              : null,
        ),
      );
      queuedIds.add(row.id);
    }
    merged.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    return merged;
  }

  /// GPS check-ins and session-code rows in one timeline (newest first).
  List<Widget> _buildMergedCheckInCards(BuildContext context) {
    final rows = <({DateTime capturedAt, Widget card})>[];
    final shownSessionCodeIds = <String>{};

    for (final e in _checkIns) {
      rows.add((
        capturedAt: e.capturedAt,
        card: _buildPendingCheckInCard(context, e),
      ));
      final code = e.sessionCodeRaw?.trim();
      if (code != null && code.isNotEmpty) {
        final stud = AttendanceStore.studentMapById()[e.studentId];
        final reg = stud?.registrationNumber.trim().toUpperCase() ??
            e.studentId.trim().toUpperCase();
        if (reg.isNotEmpty) {
          shownSessionCodeIds.add(
            '${normalizeSessionCodeInput(code)}_$reg',
          );
        }
      }
    }

    for (final e in _items) {
      if (shownSessionCodeIds.contains(e.id)) continue;
      rows.add((
        capturedAt: e.capturedAt,
        card: _buildPendingSessionCard(context, e),
      ));
    }

    rows.sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    return rows.map((r) => r.card).toList();
  }

  Widget _uploadedTick({required bool uploaded}) {
    if (!uploaded) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle_rounded, size: 18, color: AppTheme.success),
        const SizedBox(width: 4),
        Text(
          'Uploaded',
          style: TextStyle(
            color: AppTheme.success,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ],
    );
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
    final codeLabel = e.sessionCodeRaw?.trim().isNotEmpty == true
        ? normalizeSessionCodeInput(e.sessionCodeRaw!.trim())
        : (sid != null ? normalizeSessionCodeInput(sid.sessionCode) : null);
    final sessionLabel = codeLabel != null
        ? 'Session code $codeLabel'
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
                    'Check-in',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (_uploadedEntryIds.contains(e.id)) ...[
                  const SizedBox(width: 8),
                  _uploadedTick(uploaded: true),
                  const SizedBox(width: 8),
                ],
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _checkInQueueStatusColor(e.status)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _checkInQueueStatusText(e.status),
                    style: TextStyle(
                      color: _checkInQueueStatusColor(e.status),
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
                if (_uploadedEntryIds.contains(e.id)) ...[
                  const SizedBox(width: 8),
                  _uploadedTick(uploaded: true),
                  const SizedBox(width: 8),
                ],
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _statusColor(e.status).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _statusText(e),
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
            if (e.status == PendingSessionCodeStatus.queued ||
                e.status == PendingSessionCodeStatus.approved) ...[
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
            'Offline: queued check-ins upload when internet is available.',
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
      if (_checkIns.isNotEmpty || _items.isNotEmpty) ...[
        Text(
          'Check-ins',
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          'Saved on this device for up to 7 days. Queued check-ins upload when '
          'you are online; approved check-ins stay visible for the retention period.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppTheme.textSecondary, height: 1.35),
        ),
        const SizedBox(height: 8),
        ..._buildMergedCheckInCards(context),
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
        title: const Text('Check-ins'),
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
                            'Offline: queued check-ins will sync when internet returns.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppTheme.textSecondary),
                          ),
                          const SizedBox(height: 8),
                        ],
                        _buildSyncSummaryCard(context),
                        const SizedBox(height: 8),
                        const Text(
                          'No check-ins in the last 7 days.',
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
