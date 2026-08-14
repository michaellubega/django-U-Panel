import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import '../../core/constants/app_constants.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/auth/student_registration_number.dart';
import '../../core/auth/user_role.dart';
import '../../core/api/api_collections.dart';
import '../../core/api/api_store.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/device/device_identity.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/debounced_callback.dart';
import '../../core/widgets/content_skeleton.dart';
import '../../core/location/location_permission.dart';
import '../../core/location/location_resolving_panel.dart';
import '../../core/location/student_location_priming.dart';
import 'roll_cell_status.dart';
import 'models/attendance_models.dart';
import 'assigned_lecturer_field.dart';
import 'attendance_list_hierarchy.dart';
import 'check_in_outcome.dart';
import 'check_in_rejection.dart';
import 'data/attendance_repository.dart';
import 'data/attendance_remote_record_watch.dart';
import 'data/attendance_remote_sign_in_watch.dart';
import 'data/attendance_rtd_record_watch.dart';
import 'data/attendance_offline_sync.dart';
import 'student_attendance_live_sync.dart';
import 'data/pending_session_code_claim_upload.dart';
import 'data/pending_session_code_queue.dart';
import 'live_session_check_in_meter.dart';
import 'pending_sessions_screen.dart';
import 'student_check_in_progress_screen.dart';
import 'offline_queue_location_screen.dart';
import 'unknown_session_code_confirm.dart';
import 'attendance_list_title.dart';
import 'qa_program_session_ui.dart';
import '../../core/navigation/app_navigator.dart';
import '../../core/navigation/app_section.dart';
import '../../core/navigation/screen_refresh.dart';

/// Year options for attendance: Year 1 to Year 5 (value "1".."5").
const List<String> _attendanceYearValues = ['1', '2', '3', '4', '5'];
String _attendanceYearLabel(String value) => 'Year $value';

/// Semester options: Sem 1 or Sem 2.
const List<String> _attendanceSemValues = ['1', '2'];
String _attendanceSemLabel(String value) => 'Sem $value';

String _formatTimeOfDay24h(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

Future<void> _waitForAuthRoleHydration() async {
  final deadline = DateTime.now().add(const Duration(seconds: 6));
  for (;;) {
    final a = AuthRepository.instance;
    if (a.adminCheckDone && a.lecturerCheckDone) return;
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

/// Edit/delete list and destructive QA actions.
bool attendanceListAllowsMaintenance(AttendanceList list) {
  final a = AuthRepository.instance;
  if (!a.adminCheckDone || !a.lecturerCheckDone) return false;
  if (a.isAdmin) return true;
  if (a.isLecturer) {
    final uid = a.currentUserId;
    if (uid == null || uid.isEmpty) return false;
    return attendanceListAccessibleToLecturer(list, uid);
  }
  return false;
}

/// Sign-in flows: warm local cache quickly; avoid blocking on full [loadAll].
Future<void> _loadAttendanceStoreForSignIn({bool? onlineHint}) async {
  final online = onlineHint ??
      AppConnectivity.instance.isOnline ||
      AppConnectivity.instance.hasNetworkInterface;
  try {
    await AttendanceRepository.instance.warmFromLocalSnapshot();
    if (AttendanceRepository.instance.hasCachedStore) {
      if (online) {
        unawaited(AttendanceRepository.instance.bootstrapLoadIfNeeded());
        unawaited(AttendanceOfflineSync.drainSessionValidationFirst());
      }
      return;
    }
    if (AttendanceRepository.isStudentScopedUser()) {
      await AttendanceRepository.instance
          .loadStudentAttendanceForProfile(force: false)
          .timeout(online ? const Duration(seconds: 2) : const Duration(seconds: 4));
      return;
    }
    await AttendanceRepository.instance
        .loadAttendanceListsFirst(force: false)
        .timeout(online ? const Duration(seconds: 2) : const Duration(seconds: 4));
  } catch (_) {}
}

TimeOfDay _parseTimeStringForPicker(String raw) {
  final m = RegExp(r'^(\d{1,2})\s*:\s*(\d{1,2})').firstMatch(raw.trim());
  if (m != null) {
    final h = int.tryParse(m.group(1)!);
    final min = int.tryParse(m.group(2)!);
    if (h != null &&
        min != null &&
        h >= 0 &&
        h <= 23 &&
        min >= 0 &&
        min <= 59) {
      return TimeOfDay(hour: h, minute: min);
    }
  }
  return TimeOfDay.fromDateTime(DateTime.now());
}

Future<void> _pickTimeIntoController({
  required BuildContext context,
  required TextEditingController controller,
  required void Function(void Function()) setState,
}) async {
  final initial = _parseTimeStringForPicker(controller.text);
  final picked = await showTimePicker(
    context: context,
    initialTime: initial,
  );
  if (picked != null && context.mounted) {
    setState(() => controller.text = _formatTimeOfDay24h(picked));
  }
}

Widget _timePickerFormField({
  required BuildContext context,
  required TextEditingController controller,
  required Future<void> Function() onPickTime,
}) {
  return TextFormField(
    controller: controller,
    readOnly: true,
    decoration: InputDecoration(
      labelText: 'Time',
      hintText: 'Tap for clock',
      suffixIcon: IconButton(
        icon: const Icon(Icons.schedule_rounded),
        tooltip: 'Choose time',
        onPressed: onPickTime,
      ),
    ),
    onTap: onPickTime,
    validator: (v) => (v == null || v.trim().isEmpty) ? 'Choose a time' : null,
  );
}

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({
    super.key,
    this.shellSection = AppSection.attendance,
  });

  final AppSection shellSection;

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    AuthRepository.instance.addListener(_onAuthOrStoreChanged);
    AttendanceRepository.instance.addListener(_onAuthOrStoreChanged);
    _syncLoadingFromStore();
    unawaited(
      AttendanceRepository.instance.warmFromLocalSnapshot().then((_) {
        if (!mounted) return;
        _syncLoadingFromStore();
        setState(() {});
      }),
    );
    unawaited(StudentAttendanceLiveSync.activate());
    // AppShell bootstraps warm/load — only fetch here when the store is still empty.
    if (_loading &&
        !AttendanceRepository.instance.hasCachedStore &&
        !AttendanceRepository.instance.isLoaded) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    AuthRepository.instance.removeListener(_onAuthOrStoreChanged);
    AttendanceRepository.instance.removeListener(_onAuthOrStoreChanged);
    super.dispose();
  }

  void _onAuthOrStoreChanged() {
    if (!mounted) return;
    final wasLoading = _loading;
    _syncLoadingFromStore();
    final studentLive = AttendanceRepository.isStudentRecordWatchUser();
    if (wasLoading != _loading || studentLive) {
      setState(() {});
    }
    final auth = AuthRepository.instance;
    final repo = AttendanceRepository.instance;
    if (!auth.isLoggedIn) return;
    if (!auth.roleCheckDone) return;
    if (!repo.isLoaded && !repo.hasCachedStore) {
      unawaited(_load());
      return;
    }
    final student = auth.resolvedRole == UserRole.student;
    if (student) return;
    if (auth.showsStaffAttendanceUi) {
      unawaited(repo.syncStaffAttendanceForeground(force: false));
    }
    if (AttendanceStore.lists.isNotEmpty) return;
    if (attendanceListsForCurrentStaff().isEmpty) {
      unawaited(_load(force: true, listsOnly: true));
    }
  }

  void _syncLoadingFromStore() {
    if (AttendanceRepository.instance.isLoaded ||
        AttendanceRepository.instance.hasCachedStore ||
        AttendanceStore.lists.isNotEmpty) {
      _loading = false;
    }
  }

  static const Duration _loadTimeout = Duration(seconds: 12);
  static const Duration _refreshTimeout = Duration(seconds: 25);

  Future<void> _load({bool force = false, bool listsOnly = false}) async {
    final repo = AttendanceRepository.instance;
    await repo.warmFromLocalSnapshot();
    final blocking = !repo.isLoaded && !repo.hasCachedStore;
    if (mounted) {
      _syncLoadingFromStore();
      setState(() {
        if (blocking) {
          _loading = true;
          _loadError = null;
        } else {
          _loading = false;
        }
      });
    }

    if (!force && repo.hasCachedStore) {
      unawaited(
        repo.syncFromRemoteIfNeeded(force: false).catchError((_) {}),
      );
      return;
    }

    if (blocking) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      await _waitForAuthRoleHydration();
      final timeout = force ? _refreshTimeout : _loadTimeout;
      await repo.syncFromRemoteIfNeeded(force: force).timeout(
        timeout,
        onTimeout: () {
          throw TimeoutException('Load timed out', timeout);
        },
      );
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        final message = e is TimeoutException
            ? 'Loading attendance took too long. Pull down to retry.'
            : 'Could not load attendance lists. Check your connection and try again.';
        setState(() {
          _loading = false;
          _loadError = message;
        });
      }
    }
  }

  Future<void> _refreshAttendanceHub() async {
    final auth = AuthRepository.instance;
    final student =
        auth.roleCheckDone && auth.resolvedRole == UserRole.student;
    if (!student && auth.showsStaffAttendanceUi) {
      await AttendanceRepository.instance.syncStaffAttendanceForeground(
        force: true,
      );
      return;
    }
    await _load(force: true, listsOnly: !student);
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 400;
    final auth = AuthRepository.instance;

    // Always show layout immediately; only content area shows loading or error.
    return ScreenRefreshRegistrar(
      section: widget.shellSection,
      onRefresh: _refreshAttendanceHub,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          auth,
          AttendanceRepository.instance,
        ]),
        builder: (context, _) {
          final awaitingRole = !auth.roleCheckDone;
          final studentFlow = !auth.showsStaffAttendanceUi;
          final attendanceRepo = AttendanceRepository.instance;
          final showStaffLists =
              attendanceRepo.isLoaded ||
              attendanceRepo.hasCachedStore ||
              AttendanceStore.lists.isNotEmpty ||
              !_loading;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(
                context,
                narrow,
                studentFlow,
                onRefresh: _refreshAttendanceHub,
              ),
              Expanded(
                child: studentFlow
                    ? awaitingRole && !auth.isLikelyStudent
                        ? PullToRefreshBody(
                            onRefresh: _refreshAttendanceHub,
                            child: const ContentSkeleton(rows: 5),
                          )
                        : _SignInContent(onRefresh: _refreshAttendanceHub)
                    : !showStaffLists
                        ? PullToRefreshBody(
                            onRefresh: _refreshAttendanceHub,
                            child: const ContentSkeleton(rows: 5),
                          )
                        : _loadError != null
                            ? PullToRefreshBody(
                                onRefresh: _refreshAttendanceHub,
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Could not load attendance data',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _loadError!,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                      const SizedBox(height: 16),
                                      FilledButton(
                                        onPressed: _load,
                                        child: const Text('Retry'),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : const _AttendanceListsContent(),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    bool narrow,
    bool isStudent, {
    required Future<void> Function() onRefresh,
  }) {
    final refreshButton = RefreshIconButton(
      onRefresh: onRefresh,
      iconColor: Theme.of(context).colorScheme.primary,
    );

    if (!isStudent) {
      final isDesktop =
          MediaQuery.sizeOf(context).width >= AppConstants.desktopBreakpoint;
      if (!isDesktop) {
        return const SizedBox.shrink();
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              'Attendance',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
          refreshButton,
        ],
      );
    }

    final title = 'Sign in';
    final subtitle =
        'Enter your registration number and the class join code ($kSessionJoinCodeFormatHint).';

    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              refreshButton,
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodyMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        refreshButton,
      ],
    );
  }
}

class _ListDateBadge extends StatelessWidget {
  const _ListDateBadge({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final short = kAttendanceWeekdayShortLabels[date.weekday - 1];
    return Container(
      width: 52,
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
      decoration: BoxDecoration(
        color: AppTheme.accentLight.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'CLASS',
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppTheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              fontSize: 9,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            short,
            style: theme.textTheme.titleLarge?.copyWith(
              height: 1,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _WeekdaySelectorChips extends StatelessWidget {
  const _WeekdaySelectorChips({
    required this.selectedWeekday,
    required this.onSelectWeekday,
  });

  /// [DateTime.weekday]: 1 = Monday … 7 = Sunday.
  final int selectedWeekday;
  final ValueChanged<int> onSelectWeekday;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 1; i <= 7; i++)
          FilterChip(
            label: Text(kAttendanceWeekdayShortLabels[i - 1]),
            selected: selectedWeekday == i,
            showCheckmark: false,
            onSelected: (sel) {
              if (sel) onSelectWeekday(i);
            },
          ),
      ],
    );
  }
}

class _ListStatPill extends StatelessWidget {
  const _ListStatPill({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.softGrey),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: AppTheme.textSecondary),
          const SizedBox(width: 6),
          Text(
            value,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          Text(
            ' $label',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppTheme.textSecondary,
              height: 1.15,
            ),
          ),
        ],
      ),
    );
  }
}

class _ListJoinCodeStrip extends StatelessWidget {
  const _ListJoinCodeStrip({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.bolt_rounded, size: 20, color: AppTheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Students can join with this code',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            code,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
              color: AppTheme.primary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _AttendanceListSummaryCard extends StatelessWidget {
  const _AttendanceListSummaryCard({
    required this.list,
    required this.listSessions,
    required this.rosterCount,
    required this.rollRows,
    required this.session,
    required this.narrow,
    required this.allowListMaintenance,
    required this.onOpenDetail,
    required this.onHistory,
    required this.onStartSession,
    required this.onEdit,
    required this.onDelete,
    this.detailLoading = false,
  });

  final AttendanceList list;
  final List<AttendanceSession> listSessions;
  final int rosterCount;
  final int rollRows;
  final AttendanceSession? session;
  final bool narrow;
  final bool allowListMaintenance;
  final VoidCallback onOpenDetail;
  final VoidCallback onHistory;
  final VoidCallback onStartSession;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool detailLoading;

  String? get _joinCode {
    final s = session;
    if (s == null) return null;
    return normalizeSessionCodeInput(s.sessionCode);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final joinCode = _joinCode;
    final live = session != null;

    Widget trailingActions() {
      if (narrow) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.filledTonal(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(10),
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              style: IconButton.styleFrom(
                backgroundColor: live
                    ? AppTheme.success.withValues(alpha: 0.14)
                    : AppTheme.primary.withValues(alpha: 0.1),
                foregroundColor: live ? AppTheme.success : AppTheme.primary,
              ),
              onPressed: onStartSession,
              tooltip: live ? 'Open live session' : 'Start session',
              icon: Icon(
                live ? Icons.sensors_rounded : Icons.play_arrow_rounded,
                size: 22,
              ),
            ),
            PopupMenuButton<int>(
              tooltip: 'More options',
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (i) {
                switch (i) {
                  case 0:
                    onHistory();
                    break;
                  case 1:
                    onEdit();
                    break;
                  case 2:
                    onDelete();
                    break;
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 0,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.history_rounded, size: 22),
                    title: Text('History & roll'),
                  ),
                ),
                if (allowListMaintenance) ...[
                  const PopupMenuItem(
                    value: 1,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined, size: 22),
                      title: Text('Edit list'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 2,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline_rounded,
                          size: 22, color: AppTheme.error),
                      title: Text('Delete',
                          style: TextStyle(color: AppTheme.error)),
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.history_rounded, size: 22),
            onPressed: onHistory,
            tooltip: 'Session history & roll',
          ),
          IconButton(
            icon: Icon(
              live ? Icons.sensors_rounded : Icons.play_circle_outline_rounded,
              size: 22,
              color: live ? AppTheme.success : null,
            ),
            onPressed: onStartSession,
            tooltip: live ? 'Open live session' : 'Start session',
          ),
          if (allowListMaintenance) ...[
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 22),
              onPressed: onEdit,
              tooltip: 'Edit',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 22),
              onPressed: onDelete,
              tooltip: 'Delete',
            ),
          ],
        ],
      );
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      elevation: AppTheme.cardElevation,
      shadowColor: AppTheme.primary.withValues(alpha: 0.07),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: joinCode != null
              ? AppTheme.primary.withValues(alpha: 0.35)
              : AppTheme.softGrey.withValues(alpha: 0.85),
          width: joinCode != null ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: onOpenDetail,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ListDateBadge(date: list.date),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: AttendanceListTitleColumn(list: list),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppTheme.softGrey.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${list.yearLabel}/S${list.sem}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${list.courseSummaryLine} · ${list.time}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: AppTheme.textSecondary,
                            height: 1.28,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            _ListStatPill(
                              icon: Icons.event_note_rounded,
                              value: detailLoading
                                  ? '…'
                                  : '${listSessions.length}',
                              label: listSessions.length == 1
                                  ? 'session'
                                  : 'sessions',
                            ),
                            _ListStatPill(
                              icon: Icons.fact_check_outlined,
                              value: detailLoading ? '…' : '$rollRows',
                              label: rollRows == 1 ? 'row' : 'rows',
                            ),
                            _ListStatPill(
                              icon: Icons.groups_outlined,
                              value: detailLoading ? '…' : '$rosterCount',
                              label: 'on roster',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  trailingActions(),
                ],
              ),
              if (joinCode != null) ...[
                const SizedBox(height: 14),
                _ListJoinCodeStrip(code: joinCode),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-page view: programs for one class day (Day / Evening; Weekend on Sat–Sun only).
class AttendanceDayProgramsScreen extends StatelessWidget {
  const AttendanceDayProgramsScreen({
    super.key,
    required this.weekday,
    this.scopedLists,
    this.hubTitle,
  });

  final int weekday;

  /// When set, only these lists are shown (e.g. present/absent today filter).
  final Iterable<AttendanceList>? scopedLists;
  final String? hubTitle;

  List<AttendanceList> _allLists() =>
      attendanceListsFromOptionalScope(scopedLists);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AttendanceRepository.instance,
      builder: (context, _) {
        final allLists = _allLists();
        return _buildBody(context, allLists);
      },
    );
  }

  Widget _buildBody(BuildContext context, List<AttendanceList> allLists) {
    final programs = programsWithListsForWeekday(allLists, weekday);
    final dayLabel = weekdayFullLabel(weekday);
    final total = listCountOnWeekday(allLists, weekday);

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: 'Back',
        ),
        title: Text(hubTitle == null ? dayLabel : '$dayLabel · $hubTitle'),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: qaWeekdayAppBarGradient(weekday),
            ),
          ),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppTheme.background,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppTheme.softGrey.withValues(alpha: 0.9),
              ),
            ),
            child: Text(
              '$total ${total == 1 ? 'class list' : 'class lists'} on $dayLabel',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          const SizedBox(height: 16),
          if (programs.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No programs with lists on $dayLabel.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            )
          else
            ...programs.map((program) {
              final n = listCountOnWeekdayProgram(allLists, weekday, program);
              return QaProgramHubTile(
                program: program,
                listCount: n,
                onTap: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (ctx) => AttendanceProgramListsScreen(
                        weekday: weekday,
                        program: program,
                        scopedLists: scopedLists,
                        hubTitle: hubTitle,
                      ),
                    ),
                  );
                },
              );
            }),
        ],
      ),
    );
  }
}

/// Full-page QA view: attendance lists for one class day and [AttendanceProgram].
class AttendanceProgramListsScreen extends StatefulWidget {
  const AttendanceProgramListsScreen({
    super.key,
    required this.weekday,
    required this.program,
    this.scopedLists,
    this.hubTitle,
  });

  final int weekday;
  final AttendanceProgram program;
  final Iterable<AttendanceList>? scopedLists;
  final String? hubTitle;

  @override
  State<AttendanceProgramListsScreen> createState() =>
      _AttendanceProgramListsScreenState();
}

class _AttendanceProgramListsScreenState
    extends State<AttendanceProgramListsScreen> {
  late final DebouncedCallback _repoRebuild = DebouncedCallback(
    delay: const Duration(milliseconds: 180),
    callback: () {
      if (mounted) setState(() {});
    },
  );

  @override
  void initState() {
    super.initState();
    AttendanceRepository.instance.addListener(_onRepo);
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefetchListDetails());
  }

  @override
  void dispose() {
    AttendanceRepository.instance.removeListener(_onRepo);
    _repoRebuild.dispose();
    super.dispose();
  }

  void _onRepo() {
    if (!mounted) return;
    _repoRebuild.schedule();
  }

  List<AttendanceList> _listsForScreen() {
    final source = attendanceListsFromOptionalScope(widget.scopedLists);
    return listsForWeekdayAndProgram(
      source,
      widget.weekday,
      widget.program,
    );
  }

  void _prefetchListDetails() {
    final lists = [..._listsForScreen()];
    lists.sort((a, b) {
      int score(AttendanceList l) {
        var s = 0;
        if (l.status == AttendanceListStatus.active) s += 100;
        if (AttendanceStore.sessions.any(
          (session) => session.listId == l.id && session.isActive,
        )) {
          s += 200;
        }
        return s;
      }

      return score(b).compareTo(score(a));
    });
    AttendanceRepository.instance.prefetchListAttendanceDataBatch(
      lists.map((l) => l.id),
    );
  }

  Future<void> _reloadVisibleLists() async {
    final lists = _listsForScreen();
    await AttendanceRepository.instance.loadListAttendanceDataBatch(
      lists.map((l) => l.id),
      force: true,
    );
    if (mounted) setState(() {});
  }
  Future<void> _openEditScreen(BuildContext context, String listId) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => EditAttendanceListScreen(listId: listId),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openStartSessionScreen(
      BuildContext context, AttendanceList list) async {
    final activeSessions = AttendanceStore.sessions
        .where((s) => s.listId == list.id && s.isActive)
        .toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    final resume = activeSessions.isNotEmpty ? activeSessions.first : null;
    await pushAppPage<bool>(
      context,
      StartSessionScreen(
        list: list,
        resumeSession: resume,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _confirmDelete(
      BuildContext context, String listId, VoidCallback onDeleted) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete attendance list?'),
        content: const Text(
            'This will remove the attendance list and its sign-in records. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      try {
        await AttendanceRepository.instance.removeList(listId);
        onDeleted();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Attendance list deleted')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete: $e')),
          );
        }
      }
    }
  }

  Widget _buildListSummaryCard(
    BuildContext context,
    AttendanceList list,
    bool narrow,
  ) {
    final repo = AttendanceRepository.instance;
    final detailLoading = repo.listDetailShowsSkeleton(list.id);
    final listSessions = AttendanceStore.sessionsForListNewestFirst(list.id);
    final rosterCount =
        AttendanceStore.studentIdsSignedIntoList(list.id).length;
    final rollRows = AttendanceStore.recordCountForList(list.id);
    final activeSessions = listSessions.where((s) => s.isActive).toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    final session = activeSessions.isNotEmpty ? activeSessions.first : null;
    return _AttendanceListSummaryCard(
      list: list,
      listSessions: listSessions,
      rosterCount: rosterCount,
      rollRows: rollRows,
      session: session,
      narrow: narrow,
      detailLoading: detailLoading,
      allowListMaintenance: attendanceListAllowsMaintenance(list),
      onOpenDetail: () {
        unawaited(
          AttendanceRepository.instance.loadListAttendanceData(list.id),
        );
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (ctx) => SessionCheckInsScreen(list: list),
          ),
        );
      },
      onHistory: () {
        unawaited(
          AttendanceRepository.instance.loadListAttendanceData(list.id),
        );
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (ctx) => SessionCheckInsScreen(list: list),
          ),
        );
      },
      onStartSession: () => _openStartSessionScreen(context, list),
      onEdit: () => _openEditScreen(context, list.id),
      onDelete: () => _confirmDelete(context, list.id, () => setState(() {})),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lists = _listsForScreen();
    final narrow = MediaQuery.of(context).size.width < 500;
    final count = lists.length;
    final dayLabel = weekdayFullLabel(widget.weekday);

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: 'Back',
        ),
        title: Text(
          widget.hubTitle == null
              ? '$dayLabel · ${widget.program.label}'
              : '$dayLabel · ${widget.program.label} · ${widget.hubTitle}',
        ),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: qaProgramAppBarGradient(widget.program),
            ),
          ),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: RefreshIndicator(
        color: AppTheme.primary,
        onRefresh: _reloadVisibleLists,
        child: count == 0
            ? QaProgramListsEmptyState(program: widget.program)
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 36),
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.background,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AppTheme.softGrey.withValues(alpha: 0.9),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.dashboard_customize_outlined,
                          color: AppTheme.primary.withValues(alpha: 0.85),
                          size: 22,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '$count ${count == 1 ? 'class list' : 'class lists'} · $dayLabel · ${widget.program.label}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  ...lists.asMap().entries.map((entry) {
                    final i = entry.key;
                    final list = entry.value;
                    return Column(
                      children: [
                        if (i > 0) const SizedBox(height: 12),
                        _buildListSummaryCard(context, list, narrow),
                      ],
                    );
                  }),
                ],
              ),
      ),
    );
  }
}

/// QA: hub to open program-specific list pages + create list.
class _AttendanceListsContent extends StatefulWidget {
  const _AttendanceListsContent();

  @override
  State<_AttendanceListsContent> createState() =>
      _AttendanceListsContentState();
}

class _AttendanceListsContentState extends State<_AttendanceListsContent> {
  Future<void> _openCreateScreen() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => const CreateAttendanceListScreen(),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final narrow = MediaQuery.of(context).size.width < 500;
    Future<void> reloadLists() async {
      await AttendanceRepository.instance.refreshAttendanceLists(force: true);
    }

    return ListenableBuilder(
      listenable: AttendanceRepository.instance,
      builder: (context, _) {
        final attendanceLists = attendanceListsForCurrentStaff();

        return PullToRefreshBody(
      onRefresh: reloadLists,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (narrow)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _openCreateScreen,
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('Create attendance list'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            )
          else
            FilledButton.icon(
              onPressed: _openCreateScreen,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('Create attendance list'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
            ),
          const SizedBox(height: 10),
          Text(
            'Class days',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Pick a day, then program — weekend only Sat–Sun.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppTheme.textSecondary,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          if (attendanceLists.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Text(
                'No attendance lists yet. Create one above, then open the class day you chose.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                  height: 1.45,
                ),
              ),
            ),
          ...weekdaysWithLists(attendanceLists).map((weekday) {
            final n = listCountOnWeekday(attendanceLists, weekday);
            return QaWeekdayHubTile(
              weekday: weekday,
              listCount: n,
              onTap: () async {
                await Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (ctx) =>
                        AttendanceDayProgramsScreen(weekday: weekday),
                  ),
                );
                if (mounted) setState(() {});
              },
            );
          }),
        ],
      ),
    );
      },
    );
  }
}

/// All sessions for one attendance list (history) — tap a row for the full roll.
class AttendanceListSessionsScreen extends StatefulWidget {
  const AttendanceListSessionsScreen({super.key, required this.list});

  final AttendanceList list;

  @override
  State<AttendanceListSessionsScreen> createState() =>
      _AttendanceListSessionsScreenState();
}

class _AttendanceListSessionsScreenState
    extends State<AttendanceListSessionsScreen> {
  late final DebouncedCallback _repoRebuild = DebouncedCallback(
    delay: const Duration(milliseconds: 180),
    callback: () {
      if (mounted) setState(() {});
    },
  );

  @override
  void initState() {
    super.initState();
    AttendanceRepository.instance.addListener(_onRepo);
    unawaited(_reload());
  }

  @override
  void dispose() {
    AttendanceRepository.instance.removeListener(_onRepo);
    _repoRebuild.dispose();
    super.dispose();
  }

  void _onRepo() {
    if (!mounted) return;
    _repoRebuild.schedule();
  }

  Future<void> _reload({bool force = false}) async {
    await AttendanceRepository.instance.warmFromLocalSnapshot();
    if (mounted) setState(() {});
    if (!force && AttendanceRepository.instance.hasLocalListData(widget.list.id)) {
      unawaited(
        AttendanceRepository.instance
            .loadListAttendanceData(widget.list.id, force: false)
            .then((_) {
          if (mounted) setState(() {});
        }),
      );
      return;
    }
    await AttendanceRepository.instance.loadListAttendanceData(
      widget.list.id,
      force: force,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final repo = AttendanceRepository.instance;
    final detailLoading = repo.listDetailShowsSkeleton(widget.list.id);
    final sessions = AttendanceStore.sessionsForListNewestFirst(widget.list.id);
    return Scaffold(
      appBar: AppBar(
        title: AttendanceListTitleColumn(
          list: widget.list,
          titleStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
          subtitleStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.85),
              ),
          titleMaxLines: 1,
          subtitleMaxLines: 1,
        ),
        actions: [
          RefreshIconButton(onRefresh: () => _reload(force: true)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _reload(force: true),
        child: detailLoading
            ? ListView(
                physics: kRefreshScrollPhysics,
                children: const [
                  SizedBox(height: 120),
                  Center(child: ContentSkeleton(rows: 4)),
                ],
              )
            : sessions.isEmpty
            ? ListView(
                physics: kRefreshScrollPhysics,
                children: const [
                  SizedBox(height: 120),
                  Center(
                    child: Text(
                      'No sessions yet. Start one from the attendance list.',
                    ),
                  ),
                ],
              )
            : ListView.builder(
                physics: kRefreshScrollPhysics,
                padding: const EdgeInsets.all(16),
              itemCount: sessions.length,
              itemBuilder: (context, i) {
                final s = sessions[i];
                final recs = AttendanceStore.recordsForSession(s.id);
                final present = recs.where((r) => r.present).length;
                final absent = recs.where((r) => !r.present).length;
                final active = s.isActive;
                final label = normalizeSessionCodeInput(s.sessionCode);
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: Icon(
                      active ? Icons.play_circle_rounded : Icons.event_busy,
                      color: active ? AppTheme.primary : AppTheme.textSecondary,
                    ),
                    title: Text('Code $label'),
                    subtitle: Text(
                      '${s.startTime.toLocal()} · ${active ? 'Live' : 'Ended'} · '
                      '$present present · $absent absent · ${recs.length} rows',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () async {
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (ctx) =>
                              SessionCheckInsScreen(list: widget.list),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                );
              },
            ),
      ),
    );
  }
}

/// Start a check-in session (code + location + expiry).
///
/// When [resumeSession] is an active session for this list, opens directly on
/// the running-session view (timer + code). Popping that screen does not end
/// the session.
class StartSessionScreen extends StatefulWidget {
  const StartSessionScreen({
    super.key,
    required this.list,
    this.resumeSession,
  });
  final AttendanceList list;

  /// If set and still active for [list], the UI opens on the join-code screen.
  final AttendanceSession? resumeSession;

  @override
  State<StartSessionScreen> createState() => _StartSessionScreenState();
}

class _StartSessionScreenState extends State<StartSessionScreen> {
  final _createdByC = TextEditingController();
  double _radiusMeters = 50;
  int _durationMinutes = 15;
  bool _remoteLearning = false;
  Position? _position;
  String? _locationError;
  bool _starting = false;
  bool _resolvingLocation = false;
  bool _locationServiceDisabled = false;
  bool _locationPermissionBlocked = false;
  AttendanceSession? _startedSession;
  Future<void>? _locationLoad;

  static const List<double> _radiusOptions = [25, 50, 100, 150, 1500];
  static const List<int> _durationOptions = [1, 2, 10, 15, 20];

  bool get _lecturerOnly {
    final auth = AuthRepository.instance;
    return auth.showsStaffAttendanceUi &&
        !auth.isAdmin &&
        auth.resolvedRole != UserRole.kiuAdmin;
  }

  void _prefillCreatedByFromName(String? name) {
    final n = name?.trim();
    if (n == null || n.isEmpty) return;
    if (_createdByC.text.trim().isNotEmpty) return;
    _createdByC.text = n;
  }

  Future<void> _resolveLecturerCreatedBy() async {
    if (!_lecturerOnly) return;
    if (_createdByC.text.trim().isNotEmpty) return;
    final auth = AuthRepository.instance;
    var name = auth.currentFullName?.trim();
    if (name == null || name.isEmpty) {
      final profile = await auth.profileForCurrentUser();
      name = profile?['fullName']?.trim();
    }
    if (name == null || name.isEmpty) {
      final uid = auth.currentUserId?.trim();
      if (uid != null && uid.isNotEmpty) {
        try {
          final snap = await apiStore()
              .collection(ApiCollections.lecturers)
              .doc(uid)
              .get();
          name = (snap.data()?['fullName'] as String?)?.trim();
        } catch (_) {}
      }
    }
    if (!mounted) return;
    if (name != null && name.isNotEmpty) {
      setState(() => _prefillCreatedByFromName(name));
    }
  }

  Future<String> _sessionCreatedByForStart() async {
    if (!_lecturerOnly) {
      return _createdByC.text.trim();
    }
    final fromField = _createdByC.text.trim();
    if (fromField.isNotEmpty) return fromField;
    final auth = AuthRepository.instance;
    final name = auth.currentFullName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final staff = auth.currentStaffNumber?.trim();
    if (staff != null && staff.isNotEmpty) return staff;
    final email = auth.currentEmail?.trim();
    if (email != null && email.isNotEmpty) return email;
    await _resolveLecturerCreatedBy();
    final resolved = _createdByC.text.trim();
    if (resolved.isNotEmpty) return resolved;
    return 'Lecturer';
  }

  @override
  void initState() {
    super.initState();
    final resume = widget.resumeSession;
    if (resume != null && resume.listId == widget.list.id && resume.isActive) {
      _startedSession = resume;
    } else {
      if (_lecturerOnly) {
        _prefillCreatedByFromName(AuthRepository.instance.currentFullName);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          AttendanceRepository.instance.prewarmFirestoreForSessionCreate(
            widget.list.id,
          ),
        );
        if (!_remoteLearning) {
          unawaited(_getLocation());
        }
        if (_lecturerOnly) {
          unawaited(_resolveLecturerCreatedBy());
        }
      });
    }
  }

  @override
  void dispose() {
    _createdByC.dispose();
    super.dispose();
  }

  Future<void> _getLocation() {
    if (_locationLoad != null) return _locationLoad!;
    final run = _resolveLocationForPanel();
    _locationLoad = run;
    return run.whenComplete(() {
      if (identical(_locationLoad, run)) {
        _locationLoad = null;
      }
    });
  }

  Future<void> _resolveLocationForPanel() async {
    if (_remoteLearning) return;

    if (!await isDeviceLocationServiceEnabled()) {
      if (!mounted) return;
      setState(() {
        _locationServiceDisabled = true;
        _locationError = null;
        _resolvingLocation = false;
      });
      return;
    }

    setState(() {
      _locationError = null;
      _locationServiceDisabled = false;
      _locationPermissionBlocked = false;
      _resolvingLocation = true;
    });

    final r = await acquireCurrentGpsPosition(
      timeLimit: AppConnectivity.instance.isOnline
          ? const Duration(seconds: 5)
          : const Duration(seconds: 8),
      forceFresh: false,
    );
    if (!mounted) return;

    setState(() {
      _resolvingLocation = false;
      if (r.locationServiceDisabled) {
        _locationServiceDisabled = true;
        _position = null;
        return;
      }
      if (r.position != null) {
        _position = r.position;
        _locationError = null;
      } else {
        _position = null;
        _locationError = r.errorMessage ??
            'Could not read your current location. Turn on GPS and try again.';
        _locationPermissionBlocked = r.permissionBlocked;
      }
    });
  }

  Future<Position?> _resolvePositionForSessionStart() async {
    final cached = _position;
    if (cached != null &&
        positionCapturedWithin(cached, const Duration(seconds: 60))) {
      return cached;
    }
    if (_resolvingLocation && _locationLoad != null) {
      await _locationLoad;
      final refreshed = _position;
      if (refreshed != null &&
          positionCapturedWithin(refreshed, const Duration(seconds: 60))) {
        return refreshed;
      }
    }
    final r = await acquireCurrentGpsPosition(
      timeLimit: const Duration(seconds: 10),
      reuseMaxAge: const Duration(seconds: 60),
      forceFresh: true,
    );
    if (!mounted) return r.position;
    setState(() {
      _resolvingLocation = false;
      if (r.locationServiceDisabled) {
        _locationServiceDisabled = true;
        _position = null;
        return;
      }
      if (r.position != null) {
        _position = r.position;
        _locationError = null;
      } else {
        _position = null;
        _locationError = r.errorMessage ??
            'Could not read your current location. Turn on GPS and try again.';
        _locationPermissionBlocked = r.permissionBlocked;
      }
    });
    return r.position;
  }

  Future<void> _startSession() async {
    if (_starting) {
      return;
    }

    var activeForList = AttendanceStore.sessions
        .where((s) => s.listId == widget.list.id && s.isActive)
        .toList();
    activeForList.sort((a, b) => b.startTime.compareTo(a.startTime));
    if (activeForList.isNotEmpty) {
      if (!mounted) {
        return;
      }
      setState(() => _startedSession = activeForList.first);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This class list already has a live session. Showing the join code.',
          ),
        ),
      );
      return;
    }

    final startIntentAt = DateTime.now();
    setState(() => _starting = true);
    try {
      final parallel = await Future.wait<Object?>([
        _sessionCreatedByForStart(),
        if (_remoteLearning)
          Future<Position?>.value(_position)
        else
          _resolvePositionForSessionStart(),
      ]);
      if (!mounted) return;

      final createdBy = parallel[0]! as String;
      if (!_lecturerOnly && createdBy.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter your name (QA officer)')),
        );
        return;
      }

      double latitude;
      double longitude;
      if (_remoteLearning) {
        latitude = _position?.latitude ?? 0;
        longitude = _position?.longitude ?? 0;
      } else {
        final position = parallel[1] as Position?;
        if (position == null) {
          final msg = _locationError ??
              'Turn on GPS, allow location for U-Panel, then tap Refresh location.';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), duration: const Duration(seconds: 6)),
          );
          return;
        }
        latitude = position.latitude;
        longitude = position.longitude;
      }

      if (!mounted) {
        return;
      }
      activeForList = AttendanceStore.sessions
          .where((s) => s.listId == widget.list.id && s.isActive)
          .toList();
      activeForList.sort((a, b) => b.startTime.compareTo(a.startTime));
      if (activeForList.isNotEmpty) {
        setState(() {
          _starting = false;
          _startedSession = activeForList.first;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'A live session was started while preparing. Showing that join code.',
            ),
          ),
        );
        return;
      }

      final created = await AttendanceRepository.instance.createSession(
        listId: widget.list.id,
        createdBy: createdBy,
        latitude: latitude,
        longitude: longitude,
        radiusMeters: _remoteLearning ? 0 : _radiusMeters,
        durationMinutes: Duration(minutes: _durationMinutes),
        remoteLearning: _remoteLearning,
        startIntentAt: startIntentAt,
      );
      final session = created.session;
      final noticeErr =
          created.syncedToServer ? created.sessionNoticeError : null;
      if (!mounted) {
        return;
      }
      setState(() {
        _starting = false;
        _startedSession = session;
      });
      if (created.publishingInBackground) {
        // Join code shown immediately; banner flips to Live when upload completes.
      } else if (!created.syncedToServer) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Session saved on this device only — students cannot join until it publishes. '
              'Check your connection; it will retry automatically when online.',
            ),
            duration: Duration(seconds: 8),
          ),
        );
      } else if (noticeErr != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('Session started, but notice send failed: $noticeErr'),
            duration: const Duration(seconds: 6),
          ),
        );
      } else if (_remoteLearning && created.syncedToServer) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Long-distance session started. Share the join code manually — '
              'students were not sent an automatic notification.',
            ),
            duration: Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to start session: $e')));
      }
    } finally {
      if (mounted && _starting) {
        setState(() => _starting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_startedSession != null) {
      return _SessionCodeDisplay(session: _startedSession!, list: widget.list);
    }
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        title: const Text('Start session'),
        centerTitle: true,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            QaStartSessionHeroCard(list: widget.list),
            const SizedBox(height: 28),
            QaFormSectionTitle(
              title: 'Session setup',
              subtitle: _lecturerOnly
                  ? 'Choose duration and whether students must be on campus to check in.'
                  : 'Your name is stored with this session. Radius and duration apply to student check-ins.',
            ),
            const SizedBox(height: 14),
            QaFormPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Long-distance learning'),
                    subtitle: const Text(
                      'No location radius required. Students are not sent a '
                      'push notification with the session code — share the code yourself.',
                    ),
                    value: _remoteLearning,
                    onChanged: (v) => setState(() => _remoteLearning = v),
                  ),
                  if (!_lecturerOnly) ...[
                    TextFormField(
                      controller: _createdByC,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Your name (QA officer)',
                        hintText: 'e.g. Dr. Smith',
                        prefixIcon: Icon(Icons.badge_outlined),
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],
                  if (!_remoteLearning) ...[
                    DropdownButtonFormField<double>(
                      value: _radiusMeters,
                      decoration: const InputDecoration(
                        labelText: 'Allowed radius',
                        prefixIcon: Icon(Icons.radar_rounded),
                      ),
                      items: _radiusOptions
                          .map(
                            (r) => DropdownMenuItem(
                              value: r,
                              child: Text(
                                r >= 1000
                                    ? '${(r / 1000).toStringAsFixed(1)} km'
                                    : '${r.toInt()} m',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _radiusMeters = v ?? 50),
                    ),
                    const SizedBox(height: 16),
                  ],
                  DropdownButtonFormField<int>(
                    value: _durationMinutes,
                    decoration: const InputDecoration(
                      labelText: 'Session duration (expiry)',
                      prefixIcon: Icon(Icons.timer_outlined),
                    ),
                    items: _durationOptions
                        .map(
                          (d) => DropdownMenuItem(
                            value: d,
                            child: Text('$d minutes'),
                          ),
                        )
                        .toList(),
                    onChanged: (v) =>
                        setState(() => _durationMinutes = v ?? 15),
                  ),
                ],
              ),
            ),
            if (!_remoteLearning) ...[
              const SizedBox(height: 26),
              const QaFormSectionTitle(
                title: 'Check-in location',
                subtitle:
                    'Students must be within the radius of this GPS point. '
                    'Location is prepared when you open this screen (reused for 5 minutes).',
              ),
              const SizedBox(height: 12),
              LocationResolvingPanel(
                resolving: _resolvingLocation,
                position: _position,
                errorMessage: _locationError,
                locationServiceDisabled: _locationServiceDisabled,
                permissionBlocked: _locationPermissionBlocked,
                onRetry: _getLocation,
              ),
            ] else ...[
              const SizedBox(height: 20),
              const QaInfoCallout(
                text:
                    'Long-distance mode: students can check in from anywhere. '
                    'They still need the join code and must sign in during the session window.',
              ),
              const SizedBox(height: 12),
            ],
            if (!_remoteLearning && _position != null) ...[
              const SizedBox(height: 8),
              Text(
                'Coordinates update when you tap Refresh location above.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 22),
            QaInfoCallout(
              text: _remoteLearning
                  ? 'When you start, the app creates a unique join code ($kSessionJoinCodeFormatHint). '
                      'Share it with remote students yourself (no automatic push). '
                      'Students: Sign in → Session code → enter that code, then tap the arrow to submit.'
                  : 'When you start, the app creates a unique join code ($kSessionJoinCodeFormatHint). '
                      'Students: Sign in → Session code → enter that code (not their personal student code), then tap the arrow to submit. Time and location are checked automatically.',
            ),
            const SizedBox(height: 26),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  elevation: 2,
                  shadowColor: AppTheme.primary.withValues(alpha: 0.35),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: _starting ? null : _startSession,
                icon: _starting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.play_arrow_rounded, size: 26),
                label: Text(
                  _starting ? 'Starting…' : 'Start session & show join code',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen display of session code and countdown.
class _SessionCodeDisplay extends StatefulWidget {
  const _SessionCodeDisplay({required this.session, required this.list});

  final AttendanceSession session;
  final AttendanceList list;

  @override
  State<_SessionCodeDisplay> createState() => _SessionCodeDisplayState();
}

class _SessionCodeDisplayState extends State<_SessionCodeDisplay>
    with WidgetsBindingObserver {
  Timer? _ticker;
  Timer? _rollSyncTimer;
  Timer? _expiryTimer;
  bool _closing = false;
  bool _autoEndPending = false;
  bool _publishingToServer = false;
  String _countdownLabel = '';
  RollPendingContext _rollPending = const RollPendingContext.empty();
  late final DebouncedCallback _pendingReload = DebouncedCallback(
    delay: const Duration(milliseconds: 60),
    callback: () => unawaited(_reloadRollPending()),
  );

  /// Prefer store copy so countdown stays correct after [loadAll] / sync.
  AttendanceSession get _session =>
      AttendanceStore.sessionById(widget.session.id) ?? widget.session;

  String get _codeDisplay => normalizeSessionCodeInput(_session.sessionCode);

  void _scheduleExpiryAutoClose() {
    _expiryTimer?.cancel();
    final remaining = _session.endTime.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _maybeAutoEndExpired();
      return;
    }
    _expiryTimer = Timer(remaining, () {
      if (!mounted) return;
      _maybeAutoEndExpired();
    });
  }

  void _syncCountdownLabel() {
    final session = _session;
    final remaining = session.endTime.difference(DateTime.now());
    final minsLeft = remaining.isNegative ? 0 : remaining.inMinutes;
    final secsPart =
        remaining.isNegative ? 0 : remaining.inSeconds.remainder(60);
    final label = remaining.isNegative
        ? 'Session ended'
        : '${minsLeft}m ${secsPart.toString().padLeft(2, '0')}s left';
    if (label != _countdownLabel && mounted) {
      setState(() => _countdownLabel = label);
    }
  }

  Future<void> _syncLiveRoll() async {
    if (!_session.isOpenForCheckIn) return;
    await AttendanceRepository.instance.syncLiveSessionRoll(widget.list.id);
    if (!mounted) return;
    await _reloadRollPending();
    if (mounted) setState(() {});
  }

  Future<void> _refreshPublishState() async {
    final publishing = await AttendanceRepository.instance
        .isSessionAwaitingServerPublish(_session.id);
    if (!mounted) return;
    if (publishing != _publishingToServer) {
      setState(() => _publishingToServer = publishing);
    }
  }

  void _onRepo() {
    if (mounted) setState(() {});
    _pendingReload.schedule();
  }

  Future<void> _reloadRollPending() async {
    final pending = await RollPendingContext.load();
    if (!mounted) return;
    setState(() => _rollPending = pending);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AttendanceRepository.instance.addListener(_onRepo);
    AttendanceRepository.instance
        .touchRecentListDetail(widget.list.id);
    unawaited(
      AttendanceRtdRecordWatch.instance
          .watchActiveSessionRecords(widget.session.id),
    );
    if (!AttendanceRepository.isStudentRecordWatchUser()) {
      unawaited(
        AttendanceRemoteRecordWatch.instance
            .watchActiveSessionRecords(widget.session.id),
      );
      unawaited(
        AttendanceRemoteSignInWatch.instance
            .watchActiveListSignIns(widget.list.id),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoEndExpired();
      _scheduleExpiryAutoClose();
      _syncCountdownLabel();
      unawaited(_refreshPublishState());
      unawaited(_reloadRollPending());
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _maybeAutoEndExpired();
      _syncCountdownLabel();
      if (_publishingToServer) {
        unawaited(_refreshPublishState());
      }
    });
    _rollSyncTimer = Timer.periodic(
      AttendanceRepository.liveSessionRollSyncInterval,
      (_) => unawaited(_syncLiveRoll()),
    );
    unawaited(_syncLiveRoll());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AttendanceRepository.instance.removeListener(_onRepo);
    _pendingReload.dispose();
    _ticker?.cancel();
    _rollSyncTimer?.cancel();
    _expiryTimer?.cancel();
    unawaited(AttendanceRemoteRecordWatch.instance.clearActiveSessionWatch());
    unawaited(AttendanceRemoteSignInWatch.instance.clearActiveListWatch());
    unawaited(AttendanceRtdRecordWatch.instance.clearActiveSessionWatch());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _maybeAutoEndExpired();
      _scheduleExpiryAutoClose();
    }
  }

  Future<void> _copyJoinCode() async {
    await Clipboard.setData(ClipboardData(text: _codeDisplay));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied join code $_codeDisplay'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _closeSessionAndExit({required bool automatic}) async {
    if (_closing) return;
    final sessionId = _session.id;

    if (automatic) {
      _closing = true;
      _autoEndPending = true;
      try {
        await AttendanceRepository.instance.closeSessionAndFinalizeRoll(
          sessionId,
          dismissImmediately: true,
        );
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pop(true);
      return;
    }

    setState(() => _closing = true);
    try {
      await AttendanceRepository.instance.closeSessionAndFinalizeRoll(
        sessionId,
        finalizeInBackground: false,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save roll: $e')),
      );
      setState(() => _closing = false);
    }
  }

  void _maybeAutoEndExpired() {
    final s = _session;
    if (_autoEndPending || _closing) return;
    if (!s.isExpired) return;
    unawaited(_closeSessionAndExit(automatic: true));
  }

  Future<void> _endSessionAndSaveRoll() async {
    if (_closing) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End session & save roll?'),
        content: const Text(
          'The join code will stop working. Roster students who did not check in '
          'show as Pending for up to 7 days while queued check-ins sync and verify. '
          'After 7 days, anyone still unverified is marked Absent.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('End & save'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _closeSessionAndExit(automatic: false);
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final expired = session.isExpired;
    if (_countdownLabel.isEmpty) {
      _syncCountdownLabel();
    }

    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        elevation: 0,
        centerTitle: true,
        title: const Text('Session running'),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppTheme.primary,
                AppTheme.secondary.withValues(alpha: 0.92),
              ],
            ),
          ),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: (expired
                        ? AppTheme.warning
                        : _publishingToServer
                            ? AppTheme.primary
                            : AppTheme.success)
                    .withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: (expired
                          ? AppTheme.warning
                          : _publishingToServer
                              ? AppTheme.primary
                              : AppTheme.success)
                      .withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_publishingToServer && !expired)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      expired
                          ? Icons.hourglass_bottom_rounded
                          : Icons.sensors_rounded,
                      size: 18,
                      color: expired ? AppTheme.warning : AppTheme.success,
                    ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      expired
                          ? 'Time elapsed — finalizing and closing…'
                          : _publishingToServer
                              ? 'Connecting students — share the code below'
                              : session.remoteLearning
                                  ? 'Live · long-distance (no location check)'
                                  : 'Live session · join code active',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: expired
                            ? AppTheme.warning
                            : _publishingToServer
                                ? AppTheme.primary
                                : AppTheme.success,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Material(
              elevation: 3,
              shadowColor: AppTheme.primary.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(22),
              child: InkWell(
                onTap: _copyJoinCode,
                borderRadius: BorderRadius.circular(22),
                child: Ink(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        AppTheme.background,
                        AppTheme.primary.withValues(alpha: 0.06),
                      ],
                    ),
                    border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 32, horizontal: 20),
                    child: Column(
                      children: [
                        Text(
                          'JOIN CODE',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.4,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _codeDisplay,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: 10,
                            color: AppTheme.primary,
                            fontSize: 44,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Tap the code to copy',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              session.remoteLearning
                  ? 'Long-distance session: share this code with students yourself. '
                      'They can check in from anywhere during the session window.'
                  : 'Students: Sign in → Session code → enter this code, then tap the arrow to submit.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppTheme.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _copyJoinCode,
              icon: const Icon(Icons.copy_rounded, size: 20),
              label: const Text('Copy join code'),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                color: AppTheme.background,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: AppTheme.softGrey.withValues(alpha: 0.95),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Icon(Icons.schedule_rounded,
                      color: AppTheme.primary.withValues(alpha: 0.85)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _countdownLabel.isEmpty
                          ? '…'
                          : (_countdownLabel == 'Session ended'
                              ? 'Session ended'
                              : 'Time left: $_countdownLabel'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (session.remoteLearning)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'Remote',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AppTheme.primary,
                        ),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        session.radiusMeters >= 1000
                            ? '${(session.radiusMeters / 1000).toStringAsFixed(1)} km'
                            : '${session.radiusMeters.toInt()} m',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AppTheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (expired)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppTheme.warning.withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  'This session has expired. Start a new session if students still need to join.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textPrimary,
                    height: 1.4,
                  ),
                ),
              )
            else
              const SizedBox.shrink(),
            const SizedBox(height: 14),
            LiveSessionCheckInMeter(
              snapshot: liveSessionCheckInSnapshot(
                session: session,
                list: widget.list,
                pending: _rollPending,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => SessionCheckInsScreen(
                      list: widget.list,
                    ),
                  ),
                );
                if (context.mounted) setState(() {});
              },
              icon: const Icon(Icons.list_alt_rounded, size: 20),
              label: const Text('View full roll'),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _closing ? null : _endSessionAndSaveRoll,
              icon: _closing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.stop_circle_outlined),
              label: Text(_closing ? 'Saving…' : 'End session & save roll'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Memoized roll matrix for [SessionCheckInsScreen] — avoids recomputing on every frame.
class _ConsolidatedRollModel {
  _ConsolidatedRollModel({
    required this.listSessions,
    required this.rollKeys,
    required this.studentIdsByKey,
    required this.rollRowsByKey,
    required this.studentsById,
  });

  final List<AttendanceSession> listSessions;
  final List<String> rollKeys;
  final Map<String, List<String>> studentIdsByKey;
  final Map<String, List<AttendanceRecord>> rollRowsByKey;
  final Map<String, StudentRecord> studentsById;

  static _ConsolidatedRollModel build(String listId) {
    final studentsById = AttendanceStore.rosterStudentMapForList(listId);
    final listSessions = AttendanceStore.sessions
        .where((s) => s.listId == listId)
        .toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    final listSessionIds = listSessions.map((s) => s.id).toSet();
    final listRecords = AttendanceStore.attendanceRecords
        .where((r) => listSessionIds.contains(r.sessionId))
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final studentIds = AttendanceStore.rollStudentIdsForList(listId);
    final studentIdsByKey = <String, List<String>>{};
    for (final sid in studentIds) {
      final reg =
          (studentsById[sid]?.registrationNumber ?? '—').trim().toUpperCase();
      final key = reg.isEmpty || reg == '—' ? 'sid:$sid' : 'reg:$reg';
      (studentIdsByKey[key] ??= <String>[]).add(sid);
    }
    final rollRowsByKey = <String, List<AttendanceRecord>>{};
    final keyByStudentId = <String, String>{};
    for (final entry in studentIdsByKey.entries) {
      for (final sid in entry.value) {
        keyByStudentId[sid] = entry.key;
      }
    }
    for (final r in listRecords) {
      final key = keyByStudentId[r.studentId];
      if (key == null) continue;
      (rollRowsByKey[key] ??= <AttendanceRecord>[]).add(r);
    }
    final rollKeys = studentIdsByKey.keys.toList()
      ..sort((a, b) {
        final aSid = studentIdsByKey[a]!.first;
        final bSid = studentIdsByKey[b]!.first;
        return (studentsById[aSid]?.name ?? 'Unknown')
            .toLowerCase()
            .compareTo((studentsById[bSid]?.name ?? 'Unknown').toLowerCase());
      });
    return _ConsolidatedRollModel(
      listSessions: listSessions,
      rollKeys: rollKeys,
      studentIdsByKey: studentIdsByKey,
      rollRowsByKey: rollRowsByKey,
      studentsById: studentsById,
    );
  }
}

/// Full session roll: roster + present/absent rows (after session is saved).
class SessionCheckInsScreen extends StatefulWidget {
  const SessionCheckInsScreen({
    super.key,
    required this.list,
  });
  final AttendanceList list;

  @override
  State<SessionCheckInsScreen> createState() => _SessionCheckInsScreenState();
}

class _SessionCheckInsScreenState extends State<SessionCheckInsScreen>
    with WidgetsBindingObserver {
  RollPendingContext _rollPending = const RollPendingContext.empty();
  Timer? _rollSyncTimer;
  _ConsolidatedRollModel? _rollModel;
  int _rollModelRecords = -1;
  int _rollModelSessions = -1;
  int _rollModelSignIns = -1;
  int _rollModelNameRevision = -1;
  late final DebouncedCallback _repoRebuild = DebouncedCallback(
    delay: const Duration(milliseconds: 180),
    callback: () {
      unawaited(_reloadRollPendingContext());
    },
  );

  Future<void> _reloadRollPendingContext() async {
    _rollPending = await RollPendingContext.load();
    if (mounted) setState(() {});
  }

  Future<void> _reloadListDetail({bool force = false}) async {
    _rollPending = await RollPendingContext.load();
    await AttendanceRepository.instance.warmFromLocalSnapshot();
    if (mounted) setState(() {});
    if (!force &&
        AttendanceRepository.instance.hasLocalListData(widget.list.id)) {
      unawaited(
        AttendanceRepository.instance
            .loadListAttendanceData(widget.list.id, force: false)
            .then((_) async {
          await AttendanceRepository.instance
              .ensureRollNamesResolvedForList(widget.list.id);
          if (mounted) setState(() {});
        }),
      );
      unawaited(
        AttendanceRepository.instance
            .ensureRollNamesResolvedForList(widget.list.id),
      );
      return;
    }
    await AttendanceRepository.instance.loadListAttendanceData(
      widget.list.id,
      force: force,
    );
    await AttendanceRepository.instance
        .ensureRollNamesResolvedForList(widget.list.id);
    if (mounted) setState(() {});
  }

  Future<void> _refresh() => _reloadListDetail(
        force: AttendanceRepository.instance.listDetailIsStale(widget.list.id),
      );

  _ConsolidatedRollModel _rollModelForList() {
    final listId = widget.list.id;
    final records = AttendanceStore.recordCountForList(listId);
    final sessions =
        AttendanceStore.sessions.where((s) => s.listId == listId).length;
    final signIns = AttendanceStore.studentIdsSignedIntoList(listId).length;
    final nameRevision = AttendanceStore.rollRosterNameRevision(listId);
    if (_rollModel != null &&
        _rollModelRecords == records &&
        _rollModelSessions == sessions &&
        _rollModelSignIns == signIns &&
        _rollModelNameRevision == nameRevision) {
      return _rollModel!;
    }
    _rollModelRecords = records;
    _rollModelSessions = sessions;
    _rollModelSignIns = signIns;
    _rollModelNameRevision = nameRevision;
    _rollModel = _ConsolidatedRollModel.build(listId);
    return _rollModel!;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppConnectivity.instance.addListener(_onConnectivity);
    AttendanceRepository.instance.addListener(_onRepo);
    AttendanceRepository.instance
        .touchRecentListDetail(widget.list.id);
    unawaited(AttendanceRtdRecordWatch.instance.start());
    if (!AttendanceRepository.isStudentRecordWatchUser()) {
      unawaited(AttendanceRemoteRecordWatch.instance.start());
    }
    if (!AuthRepository.instance.isStudentAuthIdentity &&
        !AttendanceRepository.isStudentScopedUser()) {
      final active = AttendanceStore.sessions
          .where((s) => s.listId == widget.list.id && s.isActive)
          .toList();
      if (active.isNotEmpty) {
        unawaited(
          AttendanceRemoteRecordWatch.instance
              .watchActiveSessionRecords(active.first.id),
        );
        unawaited(
          AttendanceRtdRecordWatch.instance
              .watchActiveSessionRecords(active.first.id),
        );
      }
      unawaited(
        AttendanceRemoteSignInWatch.instance
            .watchActiveListSignIns(widget.list.id),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_reloadListDetail(force: true));
    });
    _rollSyncTimer = Timer.periodic(
      AttendanceRepository.liveSessionRollSyncInterval,
      (_) {
        if (!mounted) return;
        final hasLive = AttendanceStore.sessions.any(
          (s) => s.listId == widget.list.id && s.isActive,
        );
        if (!hasLive) return;
        unawaited(() async {
          await AttendanceRepository.instance
              .syncLiveSessionRoll(widget.list.id);
          if (!mounted) return;
          _rollModel = null;
          await _reloadRollPendingContext();
        }());
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppConnectivity.instance.removeListener(_onConnectivity);
    AttendanceRepository.instance.removeListener(_onRepo);
    _repoRebuild.dispose();
    _rollSyncTimer?.cancel();
    unawaited(AttendanceRemoteRecordWatch.instance.clearActiveSessionWatch());
    unawaited(AttendanceRemoteSignInWatch.instance.clearActiveListWatch());
    unawaited(AttendanceRtdRecordWatch.instance.clearActiveSessionWatch());
    super.dispose();
  }

  void _onConnectivity() {
    if (!AppConnectivity.instance.hasNetworkInterface) return;
    unawaited(
      AttendanceOfflineSync.drainSessionValidationFirst().then((_) {
        unawaited(_reloadRollPendingContext());
      }),
    );
  }

  void _onRepo() {
    if (!mounted) return;
    _rollModel = null;
    _repoRebuild.schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_reloadListDetail(force: false));
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final repo = AttendanceRepository.instance;
    final detailLoading = repo.listDetailShowsSkeleton(widget.list.id);
    final roll = _rollModelForList();
    final listSessions = roll.listSessions;
    final rollKeys = roll.rollKeys;
    final studentIdsByKey = roll.studentIdsByKey;
    final rollRowsByKey = roll.rollRowsByKey;
    final studentsById = roll.studentsById;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Roll · consolidated'),
        actions: [
          RefreshIconButton(onRefresh: _refresh),
        ],
      ),
      body: detailLoading
          ? const Center(child: ContentSkeleton(rows: 6))
          : rollKeys.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No students found for this class list yet.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Card(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowHeight: 44,
                    dataRowMinHeight: 54,
                    dataRowMaxHeight: 64,
                    columnSpacing: 16,
                    columns: [
                      const DataColumn(
                        label: Text('%',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      const DataColumn(
                        label: Text(
                          'Student',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      for (final s in listSessions)
                        DataColumn(
                          label: Text(
                            _fmtDate(s.startTime),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                    rows: rollKeys.map((k) {
                      final ids = studentIdsByKey[k]!;
                      final sid = ids.first;
                      final student = studentsById[sid] ??
                          AttendanceStore.resolveStudentForRoll(
                            sid,
                            listId: widget.list.id,
                            cache: studentsById,
                          );
                      final name = student?.name ?? 'Unknown';
                      final reg = student?.registrationNumber ?? '—';
                      final rows =
                          rollRowsByKey[k] ?? const <AttendanceRecord>[];

                      String? cellLabelForSession(AttendanceSession s) {
                        return rollCellLabelForStudentSession(
                          session: s,
                          studentId: sid,
                          recordsForStudent: rows,
                          pending: _rollPending,
                        );
                      }

                      final rateSessions = listSessions
                          .where((s) => s.countsTowardRollStats)
                          .toList();
                      final rateCounts = rollRateCountsForStudentOnList(
                        studentId: sid,
                        listId: widget.list.id,
                        completedSessions: rateSessions,
                        recordsForStudent: rows,
                        pending: _rollPending,
                      );
                      final percent = rateCounts.total <= 0
                          ? '0%'
                          : '${rateCounts.percentRounded}%';

                      final displayLabelBySessionId = <String, String?>{
                        for (final s in listSessions)
                          s.id: cellLabelForSession(s),
                      };

                      return DataRow(
                        cells: [
                          DataCell(Text(
                            percent,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          )),
                          DataCell(
                            SizedBox(
                              width: 170,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    reg,
                                    style: const TextStyle(
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          for (final s in listSessions)
                            DataCell(
                              SizedBox(
                                width: 110,
                                child: () {
                                  final label = displayLabelBySessionId[s.id];
                                  final text = (label ?? '—').toLowerCase();
                                  final Color color;
                                  if (label == null) {
                                    color = AppTheme.textSecondary;
                                  } else if (label == kRollLabelPresent) {
                                    color = AppTheme.primary;
                                  } else if (label == kRollLabelPending) {
                                    color = AppTheme.warning;
                                  } else {
                                    color = AppTheme.error;
                                  }
                                  return Text(
                                    text,
                                    style: TextStyle(
                                      color: color,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  );
                                }(),
                              ),
                            ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
    );
  }
}

/// Full-screen form to create one attendance list.
class _CourseEntry {
  final TextEditingController courseC = TextEditingController();
  void dispose() => courseC.dispose();
}

List<String> _courseListFromEntries(List<_CourseEntry> entries) {
  return <String>[
    for (final e in entries) e.courseC.text.trim()
  ]..removeWhere((c) => c.isEmpty);
}

class CreateAttendanceListScreen extends StatefulWidget {
  const CreateAttendanceListScreen({super.key});

  @override
  State<CreateAttendanceListScreen> createState() =>
      _CreateAttendanceListScreenState();
}

class _CreateAttendanceListScreenState
    extends State<CreateAttendanceListScreen> {
  final _formKey = GlobalKey<FormState>();
  final _courseUnitC = TextEditingController();
  final List<_CourseEntry> _courseEntries = [_CourseEntry()];
  final _whoTaughtC = TextEditingController();
  final _timeC = TextEditingController();
  final _roomC = TextEditingController();
  String _selectedYear = '1';
  String _selectedSem = '1';
  late DateTime _listDate;
  AttendanceProgram _program = AttendanceProgram.day;
  bool _saving = false;
  final _manualStaffC = TextEditingController();

  void _prefillWhoTaughtFromName(String? name) {
    final n = name?.trim();
    if (n == null || n.isEmpty) return;
    if (_whoTaughtC.text.trim().isNotEmpty) return;
    _whoTaughtC.text = n;
  }

  Future<void> _resolveLecturerDisplayName() async {
    final auth = AuthRepository.instance;
    if (!auth.isLecturer || auth.isAdmin) return;
    if (_whoTaughtC.text.trim().isNotEmpty) return;

    var name = auth.currentFullName?.trim();
    if (name == null || name.isEmpty) {
      final profile = await auth.profileForCurrentUser();
      name = profile?['fullName']?.trim();
    }
    if (name == null || name.isEmpty) {
      final uid = auth.currentUserId?.trim();
      if (uid != null && uid.isNotEmpty) {
        try {
          final snap = await apiStore()
              .collection(ApiCollections.lecturers)
              .doc(uid)
              .get();
          name = (snap.data()?['fullName'] as String?)?.trim();
        } catch (_) {}
      }
    }
    if (!mounted) return;
    if (name != null && name.isNotEmpty) {
      setState(() => _prefillWhoTaughtFromName(name));
    }
  }

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _listDate = attendanceListDateForWeekday(n.weekday);
    _timeC.text = _formatTimeOfDay24h(TimeOfDay.fromDateTime(n));
    final auth = AuthRepository.instance;
    if (auth.isLecturer && !auth.isAdmin) {
      _prefillWhoTaughtFromName(auth.currentFullName);
    }
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _initLecturerCreateDefaults());
  }

  Future<void> _initLecturerCreateDefaults() async {
    final auth = AuthRepository.instance;
    if (!auth.isLecturer || auth.isAdmin) return;
    if (!auth.lecturerCheckDone) {
      await _waitForAuthRoleHydration();
    }
    await _resolveLecturerDisplayName();
  }

  Future<void> _pickClassTime() async {
    await _pickTimeIntoController(
      context: context,
      controller: _timeC,
      setState: setState,
    );
  }

  void _addCourse() {
    setState(() => _courseEntries.add(_CourseEntry()));
  }

  void _removeCourse(int index) {
    if (_courseEntries.length <= 1) return;
    setState(() {
      _courseEntries[index].dispose();
      _courseEntries.removeAt(index);
    });
  }

  @override
  void dispose() {
    _courseUnitC.dispose();
    _whoTaughtC.dispose();
    _manualStaffC.dispose();
    _timeC.dispose();
    _roomC.dispose();
    for (final e in _courseEntries) {
      e.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    final time = _timeC.text.trim();
    final room = _roomC.text.trim();
    final year = _selectedYear;
    final sem = _selectedSem;
    if (time.isEmpty || room.isEmpty) return;
    final whoTaught = _whoTaughtC.text.trim();
    if (whoTaught.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter name of lecturer / who taught')),
      );
      return;
    }
    final courseUnit = _courseUnitC.text.trim();
    if (courseUnit.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the course unit name')),
      );
      return;
    }
    final courseList = _courseListFromEntries(_courseEntries);
    if (courseList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one course')),
      );
      return;
    }
    final programWeekdayError = attendanceListProgramWeekdayValidationError(
      _program,
      _listDate,
    );
    if (programWeekdayError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(programWeekdayError)),
      );
      return;
    }
    final auth = AuthRepository.instance;
    final creatorUid = auth.currentUserId?.trim();
    String? lecturerUid;
    String? pendingLecturerStaffNumber;
    if (auth.adminCheckDone && auth.isAdmin) {
      final resolved =
          await AttendanceRepository.instance.resolveAssignedLecturerForAdmin(
        manualStaffNumberRaw: _manualStaffC.text,
      );
      if (!mounted) return;
      if (resolved.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(resolved.error!)),
        );
        return;
      }
      lecturerUid = resolved.uid;
      pendingLecturerStaffNumber = resolved.deferredStaffNumber;
    } else if (!auth.isAdmin) {
      lecturerUid = auth.currentUserId?.trim();
    }
    final list = AttendanceList(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      time: time,
      room: room,
      whoTaught: whoTaught,
      date: _listDate,
      program: _program,
      courses: courseList,
      year: year,
      sem: sem,
      createdBy: creatorUid,
      lecturerUid: lecturerUid,
      courseUnitName: courseUnit,
    );
    setState(() => _saving = true);
    try {
      final created = await AttendanceRepository.instance.addList(
        list,
        pendingLecturerStaffNumber: pendingLecturerStaffNumber,
      );
      if (!context.mounted) return;
      if (!created.syncedToServer) {
        final deferred = pendingLecturerStaffNumber?.trim();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              deferred != null && deferred.isNotEmpty
                  ? 'List "$courseUnit" saved on this device. '
                      'Lecturer $deferred will be linked when you are back online.'
                  : 'List "$courseUnit" saved on this device. '
                      'It will publish when you are back online.',
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Attendance list "$courseUnit" created')),
        );
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!context.mounted) return;
      final msg =
          e is Exception ? e.toString().replaceFirst('Exception: ', '') : '$e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save: $msg'),
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppConnectivity.instance,
      builder: (context, _) {
        final offline = !AppConnectivity.instance.isOnline;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Create attendance list'),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (offline) ...[
                    Card(
                      color: AppTheme.warning.withValues(alpha: 0.12),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.cloud_off_rounded,
                              color: AppTheme.warning,
                              size: 22,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'You are offline. The list will be saved on this device '
                                'and published when you reconnect.',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(height: 1.35),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _field(
                            _courseUnitC,
                            'Course unit name',
                            'e.g. Data Structures & Algorithms',
                            TextInputType.text,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'This name is used as the attendance list title everywhere '
                            'in the app (dashboard, reports, notices).',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: AppTheme.textSecondary,
                                    ),
                          ),
                          const SizedBox(height: 16),
                          _field(
                            _whoTaughtC,
                            'Name of lecturer / Who taught',
                            'e.g. Dr. Smith',
                            TextInputType.name,
                          ),
                          const SizedBox(height: 16),
                          if (AuthRepository.instance.isAdmin &&
                              AuthRepository.instance.adminCheckDone) ...[
                            AssignedLecturerField(
                              manualStaffController: _manualStaffC,
                            ),
                            const SizedBox(height: 16),
                          ] else if (AuthRepository.instance.isLecturer) ...[
                            Text(
                              'This list will be linked to your lecturer account and recorded as one you created.',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: AppTheme.textSecondary,
                                  ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          _buildCreateFormRest(context),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCreateFormRest(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Class day & program',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 8),
        _WeekdaySelectorChips(
          selectedWeekday: _listDate.weekday,
          onSelectWeekday: (w) {
            setState(
              () => _listDate = attendanceListDateForWeekday(w),
            );
          },
        ),
        const SizedBox(height: 4),
        Text(
          'Which day of the week this class runs.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
        ),
        const SizedBox(height: 12),
        Text('Program', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        SegmentedButton<AttendanceProgram>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: AttendanceProgram.day,
              label: Text('Day'),
              icon: Icon(Icons.wb_sunny_outlined, size: 18),
            ),
            ButtonSegment(
              value: AttendanceProgram.evening,
              label: Text('Evening'),
              icon: Icon(Icons.nights_stay_outlined, size: 18),
            ),
            ButtonSegment(
              value: AttendanceProgram.weekend,
              label: Text('Weekend'),
              icon: Icon(Icons.event_available_outlined, size: 18),
            ),
          ],
          selected: {_program},
          onSelectionChanged: (Set<AttendanceProgram> next) {
            if (next.isNotEmpty) {
              setState(() => _program = next.first);
            }
          },
        ),
        const SizedBox(height: 20),
        Text('Time, room, year & semester',
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 400) {
              return Column(
                children: [
                  _timePickerFormField(
                    context: context,
                    controller: _timeC,
                    onPickTime: _pickClassTime,
                  ),
                  const SizedBox(height: 12),
                  _field(_roomC, 'Room', 'e.g. A101', TextInputType.text),
                ],
              );
            }
            return Row(
              children: [
                Expanded(
                  child: _timePickerFormField(
                    context: context,
                    controller: _timeC,
                    onPickTime: _pickClassTime,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _field(_roomC, 'Room', 'e.g. A101', TextInputType.text),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 400;
            final yearDropdown = DropdownButtonFormField<String>(
              value: _selectedYear,
              decoration: const InputDecoration(labelText: 'Year'),
              items: _attendanceYearValues
                  .map((v) => DropdownMenuItem(
                        value: v,
                        child: Text(_attendanceYearLabel(v)),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _selectedYear = v ?? '1'),
            );
            final semDropdown = DropdownButtonFormField<String>(
              value: _selectedSem,
              decoration: const InputDecoration(labelText: 'Semester'),
              items: _attendanceSemValues
                  .map((v) => DropdownMenuItem(
                        value: v,
                        child: Text(_attendanceSemLabel(v)),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _selectedSem = v ?? '1'),
            );
            if (narrow) {
              return Column(
                children: [
                  yearDropdown,
                  const SizedBox(height: 12),
                  semDropdown,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: yearDropdown),
                const SizedBox(width: 12),
                Expanded(child: semDropdown),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        Text('Courses (add multiple)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Course codes or names for student check-in. '
          'The course unit name above is only the list title.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
        ),
        const SizedBox(height: 12),
        ...List.generate(_courseEntries.length, (i) {
          final e = _courseEntries[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _field(
                    e.courseC,
                    'Course',
                    'e.g. CS 101',
                    TextInputType.text,
                  ),
                ),
                if (_courseEntries.length > 1)
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                    onPressed: () => _removeCourse(i),
                    tooltip: 'Remove course',
                  ),
              ],
            ),
          );
        }),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _addCourse,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Add another course'),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded, size: 20),
          label: Text(_saving ? 'Saving...' : 'Add to list'),
        ),
      ],
    );
  }

  Widget _field(
      TextEditingController c, String label, String hint, TextInputType type) {
    return TextFormField(
      controller: c,
      decoration: InputDecoration(labelText: label, hintText: hint),
      keyboardType: type,
      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
    );
  }
}

/// Edit a single attendance list.
class EditAttendanceListScreen extends StatefulWidget {
  const EditAttendanceListScreen({super.key, required this.listId});
  final String listId;

  @override
  State<EditAttendanceListScreen> createState() =>
      _EditAttendanceListScreenState();
}

class _EditAttendanceListScreenState extends State<EditAttendanceListScreen> {
  final _formKey = GlobalKey<FormState>();
  final _courseUnitC = TextEditingController();
  final List<_CourseEntry> _courseEntries = [];
  final _whoTaughtC = TextEditingController();
  final _timeC = TextEditingController();
  final _roomC = TextEditingController();
  String _selectedYear = '1';
  String _selectedSem = '1';
  AttendanceList? _list;
  late DateTime _listDate;
  AttendanceProgram _program = AttendanceProgram.day;
  final _manualStaffC = TextEditingController();

  @override
  void initState() {
    super.initState();
    _list = AttendanceStore.listById(widget.listId);
    if (_list != null) {
      final unit = _list!.courseUnitName?.trim() ?? '';
      _courseUnitC.text =
          unit.isNotEmpty ? unit : _list!.effectiveCourseUnitName;
      _whoTaughtC.text = _list!.whoTaught;
      _timeC.text = _list!.time;
      _roomC.text = _list!.room;
      _selectedYear = _list!.year;
      _selectedSem = _list!.sem;
      final d = _list!.date;
      _listDate = attendanceListDateForWeekday(d.weekday);
      _program = _list!.program;
      for (final c in _list!.coursesSafe) {
        final e = _CourseEntry();
        e.courseC.text = c;
        _courseEntries.add(e);
      }
      if (_courseEntries.isEmpty) {
        _courseEntries.add(_CourseEntry());
      }
    } else {
      final n = DateTime.now();
      _listDate = attendanceListDateForWeekday(n.weekday);
    }
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _prefillManualStaffIdForEdit());
  }

  void _addCourse() => setState(() => _courseEntries.add(_CourseEntry()));

  void _removeCourse(int index) {
    if (_courseEntries.length <= 1) return;
    setState(() {
      _courseEntries[index].dispose();
      _courseEntries.removeAt(index);
    });
  }

  Future<void> _prefillManualStaffIdForEdit() async {
    final auth = AuthRepository.instance;
    if (!auth.isAdmin || !auth.adminCheckDone) return;
    final uid = _list?.lecturerUid?.trim();
    if (uid == null || uid.isEmpty) return;
    try {
      final snap = await apiStore()
          .collection(ApiCollections.lecturers)
          .doc(uid)
          .get();
      final sn = (snap.data()?['staffNumber'] as String?)?.trim();
      if (!mounted || sn == null || sn.isEmpty) return;
      setState(() => _manualStaffC.text = sn);
    } catch (_) {}
  }

  Future<void> _pickClassTime() async {
    await _pickTimeIntoController(
      context: context,
      controller: _timeC,
      setState: setState,
    );
  }

  @override
  void dispose() {
    _courseUnitC.dispose();
    _whoTaughtC.dispose();
    _manualStaffC.dispose();
    _timeC.dispose();
    _roomC.dispose();
    for (final e in _courseEntries) {
      e.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_list == null || !_formKey.currentState!.validate()) return;
    final courseUnit = _courseUnitC.text.trim();
    if (courseUnit.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the course unit name')),
      );
      return;
    }
    final courseList = _courseListFromEntries(_courseEntries);
    if (courseList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one course')),
      );
      return;
    }
    final programWeekdayError = attendanceListProgramWeekdayValidationError(
      _program,
      _listDate,
    );
    if (programWeekdayError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(programWeekdayError)),
      );
      return;
    }
    final auth = AuthRepository.instance;
    String? lecturerUid = _list!.lecturerUid;
    if (auth.isAdmin && auth.adminCheckDone) {
      final resolved =
          await AttendanceRepository.instance.resolveAssignedLecturerForAdmin(
        manualStaffNumberRaw: _manualStaffC.text,
      );
      if (!mounted) return;
      if (resolved.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(resolved.error!)),
        );
        return;
      }
      lecturerUid = resolved.uid ?? _list!.lecturerUid;
    }
    final updated = AttendanceList(
      id: _list!.id,
      time: _timeC.text.trim(),
      room: _roomC.text.trim(),
      whoTaught: _whoTaughtC.text.trim(),
      date: _listDate,
      program: _program,
      courses: courseList,
      year: _selectedYear,
      sem: _selectedSem,
      createdBy: _list!.createdBy,
      lecturerUid: lecturerUid,
      expectedParticipants: _list!.expectedParticipants,
      status: _list!.status,
      lecturerSignCode: _list!.lecturerSignCode,
      lecturerSignedAt: _list!.lecturerSignedAt,
      courseUnitName: courseUnit,
    );
    try {
      await AttendanceRepository.instance.updateList(updated);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Attendance list updated')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_list == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit attendance list')),
        body: const Center(child: Text('Attendance list not found')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Edit attendance list')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        controller: _courseUnitC,
                        decoration: const InputDecoration(
                          labelText: 'Course unit name',
                          hintText: 'e.g. Data Structures & Algorithms',
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This name is used as the attendance list title everywhere '
                        'in the app.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _whoTaughtC,
                        decoration: const InputDecoration(
                            labelText: 'Name of lecturer / Who taught'),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 16),
                      if (AuthRepository.instance.isAdmin &&
                          AuthRepository.instance.adminCheckDone) ...[
                        AssignedLecturerField(
                          manualStaffController: _manualStaffC,
                        ),
                        const SizedBox(height: 16),
                      ],
                      Text('Class day & program',
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  )),
                      const SizedBox(height: 8),
                      _WeekdaySelectorChips(
                        selectedWeekday: _listDate.weekday,
                        onSelectWeekday: (w) {
                          setState(
                            () => _listDate = attendanceListDateForWeekday(w),
                          );
                        },
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Which day of the week this class runs.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Text('Program',
                          style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 8),
                      SegmentedButton<AttendanceProgram>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: AttendanceProgram.day,
                            label: Text('Day'),
                            icon: Icon(Icons.wb_sunny_outlined, size: 18),
                          ),
                          ButtonSegment(
                            value: AttendanceProgram.evening,
                            label: Text('Evening'),
                            icon: Icon(Icons.nights_stay_outlined, size: 18),
                          ),
                          ButtonSegment(
                            value: AttendanceProgram.weekend,
                            label: Text('Weekend'),
                            icon:
                                Icon(Icons.event_available_outlined, size: 18),
                          ),
                        ],
                        selected: {_program},
                        onSelectionChanged: (Set<AttendanceProgram> next) {
                          if (next.isNotEmpty) {
                            setState(() => _program = next.first);
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _timePickerFormField(
                              context: context,
                              controller: _timeC,
                              onPickTime: _pickClassTime,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                              child: TextFormField(
                                  controller: _roomC,
                                  decoration: const InputDecoration(
                                      labelText: 'Room', hintText: 'e.g. A101'),
                                  validator: (v) =>
                                      (v == null || v.trim().isEmpty)
                                          ? 'Required'
                                          : null)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _selectedYear,
                              decoration:
                                  const InputDecoration(labelText: 'Year'),
                              items: _attendanceYearValues
                                  .map((v) => DropdownMenuItem(
                                        value: v,
                                        child: Text(_attendanceYearLabel(v)),
                                      ))
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _selectedYear = v ?? '1'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _selectedSem,
                              decoration:
                                  const InputDecoration(labelText: 'Semester'),
                              items: _attendanceSemValues
                                  .map((v) => DropdownMenuItem(
                                        value: v,
                                        child: Text(_attendanceSemLabel(v)),
                                      ))
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _selectedSem = v ?? '1'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Text('Courses (add multiple)',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        'Course codes or names for student check-in. '
                        'The course unit name above is only the list title.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                      ),
                      const SizedBox(height: 12),
                      ...List.generate(_courseEntries.length, (i) {
                        final e = _courseEntries[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: e.courseC,
                                  decoration: const InputDecoration(
                                    labelText: 'Course',
                                    hintText: 'e.g. CS 101',
                                  ),
                                  validator: (v) =>
                                      (v == null || v.trim().isEmpty)
                                          ? 'Required'
                                          : null,
                                ),
                              ),
                              if (_courseEntries.length > 1)
                                IconButton(
                                  icon: const Icon(
                                      Icons.remove_circle_outline_rounded),
                                  onPressed: () => _removeCourse(i),
                                  tooltip: 'Remove course',
                                ),
                            ],
                          ),
                        );
                      }),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _addCourse,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add another course'),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.check_rounded, size: 20),
                        label: const Text('Save changes'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Student sign-in: registration number + session code.
class _SignInContent extends StatefulWidget {
  const _SignInContent({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  State<_SignInContent> createState() => _SignInContentState();
}

class _SignInContentState extends State<_SignInContent> {
  final _regC = TextEditingController();
  final _sessionCodeC = TextEditingController();
  final _sessionCodeFocus = FocusNode();
  bool _busy = false;

  /// Upper-bound hint while session lookup runs; ticks down once per second.
  static const int _signInBusyCountdownSeconds = 20;
  Timer? _busyCountdownTimer;
  int _busyCountdownRemaining = 0;

  StudentRecord? _currentStudent;

  /// When true, registration came from the signed-in profile and cannot be edited.
  bool _regFromProfile = false;

  bool get _registrationFieldLocked =>
      AuthRepository.instance.isStudentAuthIdentity ||
      AttendanceRepository.isStudentScopedUser() ||
      _regFromProfile;

  void _syncRegistrationFromProfile() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = AuthRepository.instance;
      final studentAccount = auth.isStudentAuthIdentity;
      final r = auth.currentRegistrationNumber?.trim();
      if (studentAccount || (r != null && r.isNotEmpty)) {
        if (r != null && r.isNotEmpty && _regC.text != r) {
          _regC.text = r;
        }
        if (!_regFromProfile &&
            (studentAccount || (r != null && r.isNotEmpty))) {
          setState(() => _regFromProfile = true);
        }
      } else {
        if (_regFromProfile) {
          setState(() => _regFromProfile = false);
        }
        if (_currentStudent != null) {
          setState(() => _currentStudent = null);
        }
        return;
      }
      if (r == null || r.isEmpty) return;
      final student = AttendanceStore.findStudentByReg(r);
      if (_currentStudent?.id != student?.id) {
        setState(() => _currentStudent = student);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    AuthRepository.instance.addListener(_syncRegistrationFromProfile);
    AttendanceRepository.instance.addListener(_syncRegistrationFromProfile);
    AppConnectivity.instance.addListener(_onConnectivityChanged);
    _syncRegistrationFromProfile();
    unawaited(
      AuthRepository.instance.ensureStudentRegistrationHydrated().then((_) {
        if (mounted) _syncRegistrationFromProfile();
      }),
    );
    unawaited(AttendanceRepository.instance.loadStudentAttendanceForProfile());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(StudentLocationPriming.instance.primeOnAppOpen());
      unawaited(AttendanceOfflineSync.drainSessionValidationFirst().then((_) {
        if (mounted) setState(() {});
      }));
    });
  }

  @override
  void dispose() {
    _busyCountdownTimer?.cancel();
    AppConnectivity.instance.removeListener(_onConnectivityChanged);
    AuthRepository.instance.removeListener(_syncRegistrationFromProfile);
    AttendanceRepository.instance.removeListener(_syncRegistrationFromProfile);
    _regC.dispose();
    _sessionCodeC.dispose();
    _sessionCodeFocus.dispose();
    super.dispose();
  }

  void _setBusy(bool value) {
    if (value) {
      _busyCountdownTimer?.cancel();
      final online = AppConnectivity.instance.isOnline;
      if (!online) {
        _busyCountdownRemaining = _signInBusyCountdownSeconds;
        _busyCountdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) {
            _busyCountdownTimer?.cancel();
            _busyCountdownTimer = null;
            return;
          }
          setState(() {
            if (_busyCountdownRemaining > 0) {
              _busyCountdownRemaining--;
            }
          });
        });
      } else {
        _busyCountdownRemaining = 0;
      }
      setState(() => _busy = true);
    } else {
      _busyCountdownTimer?.cancel();
      _busyCountdownTimer = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _busyCountdownRemaining = 0;
        });
      } else {
        _busy = false;
        _busyCountdownRemaining = 0;
      }
    }
  }

  String _studentBusyButtonLabel() {
    if (_busyCountdownRemaining > 0) {
      return 'Checking in… ${_busyCountdownRemaining}s';
    }
    return 'Checking in…';
  }

  void _onConnectivityChanged() {
    if (!mounted) return;
    if (AppConnectivity.instance.hasNetworkInterface) {
      unawaited(AttendanceOfflineSync.drainSessionValidationFirst());
    }
    setState(() {});
  }

  void _clearSessionCodeAfterUse() {
    if (_sessionCodeC.text.isEmpty) return;
    _sessionCodeC.clear();
    if (mounted) setState(() {});
  }

  void _onStudentSessionCodeChanged(String _) {
    setState(() {});
  }

  bool get _canSubmitSessionCode =>
      !_busy &&
      _registrationFormatOk &&
      isValidJoinCodeFormat(normalizeSessionCodeInput(_sessionCodeC.text));

  Widget? _sessionCodeSubmitSuffix() {
    if (_busy) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.arrow_forward_rounded),
      tooltip: 'Submit code',
      onPressed:
          _canSubmitSessionCode ? () => unawaited(_continueToCheckIn()) : null,
    );
  }

  Future<String?> _pickCourseForFirstListSignIn(
    AttendanceList list, {
    required String studentId,
  }) async {
    final courses = list.coursesSafe;
    if (courses.isEmpty) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'This class list has no courses on file (${list.whoTaught} · ${list.room}). '
            'Ask staff to add course names to the list, then try again.',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
      return null;
    }
    if (courses.length == 1) {
      final firstEnroll = !AttendanceStore.hasStudentSignedIntoList(
        list.id,
        studentId,
      );
      if (firstEnroll && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Enrolling you on ${list.whoTaught} · ${list.room} as ${courses.first}.',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      if (!mounted) return null;
      return courses.first;
    }
    return showModalBottomSheet<String>(
      context: context,
      isDismissible: false,
      enableDrag: false,
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Join this class list',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${list.whoTaught} · ${list.room} · ${list.time}',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Choose your course',
                      style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'One-time choice for this attendance list.',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                    ),
                    const SizedBox(height: 14),
                    for (final course in courses)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(ctx).pop(course),
                            child: Text(
                              course,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
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

  bool get _registrationFormatOk =>
      StudentRegistrationNumber.validateFormat(_regC.text) == null;

  Duration get _studentSignInReachTimeout =>
      kIsWeb ? const Duration(seconds: 4) : const Duration(seconds: 2);

  Duration get _studentSignInNetworkBudget {
    final prefetchOnline = AppConnectivity.instance.isOnline ||
        AppConnectivity.instance.hasNetworkInterface;
    if (kIsWeb) {
      return prefetchOnline
          ? const Duration(seconds: 10)
          : const Duration(seconds: 6);
    }
    return prefetchOnline
        ? const Duration(seconds: 6)
        : const Duration(seconds: 3);
  }

  /// Fetches list metadata when the session is known but the list row is missing.
  Future<AttendanceList?> _resolveListForKnownSession(
    AttendanceSession session,
  ) async {
    final fromStore = AttendanceStore.listById(session.listId);
    if (fromStore != null) return fromStore;
    return AttendanceRepository.instance.resolveListById(session.listId);
  }

  void _returnToEnterNewSessionCode() {
    _sessionCodeC.clear();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sessionCodeFocus.requestFocus();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Enter the correct session code from your lecturer.',
        ),
        duration: Duration(seconds: 5),
      ),
    );
  }

  Future<void> _continueToCheckIn() async {
    final regErr = StudentRegistrationNumber.validateFormat(_regC.text);
    if (regErr != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(regErr)),
      );
      return;
    }
    final reg = StudentRegistrationNumber.normalize(_regC.text);
    final profileReg = StudentRegistrationNumber.normalize(
      AuthRepository.instance.currentRegistrationNumber?.trim() ?? '',
    );
    final requiresProfileRegistration =
        AuthRepository.instance.isStudentAuthIdentity ||
        _regFromProfile ||
        AttendanceRepository.isStudentScopedUser();
    if (requiresProfileRegistration && profileReg.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Your account has no registration number. Update your profile in Settings or contact support.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }
    if (profileReg.isNotEmpty && reg != profileReg) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Use the registration number on your profile to continue check-in.',
          ),
          duration: Duration(seconds: 5),
        ),
      );
      return;
    }
    final deviceRegBlock = await AttendanceRepository.instance
        .deviceRegistrationBlockReason(reg);
    if (!mounted) return;
    if (deviceRegBlock != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This device already registered another student. '
            'Each phone may only be used for one student.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }
    final rawCode = _sessionCodeC.text.trim();
    if (!isValidJoinCodeFormat(normalizeSessionCodeInput(rawCode))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Enter the session code from your class (e.g. $kSessionJoinCodeExample).')),
      );
      return;
    }
    _setBusy(true);
    try {
      final prefetchOnline = AppConnectivity.instance.isOnline ||
          AppConnectivity.instance.hasNetworkInterface;
      if (StudentLocationPriming.instance.lastPosition == null &&
          !StudentLocationPriming.instance.resolving) {
        unawaited(StudentLocationPriming.instance.acquireFreshForCheckIn());
      }
      unawaited(_loadAttendanceStoreForSignIn(onlineHint: prefetchOnline));

      final localSession =
          AttendanceRepository.instance.validateSessionCode(rawCode);
      final reachFuture = AppConnectivity.instance.ensureReachable(
        timeout: _studentSignInReachTimeout,
      );
      final networkBudget = _studentSignInNetworkBudget;
      final studentFuture = AttendanceRepository.instance
          .resolveStudentForRegistration(reg, fast: true);
      final resolveFuture = AttendanceRepository.instance
          .resolveSessionAndListForStudentCode(rawCode);

      final isOnline = await reachFuture;
      if (!mounted) return;
      StudentRecord? student;
      try {
        student = await studentFuture.timeout(networkBudget);
      } catch (_) {
        student = AttendanceStore.findStudentByReg(reg);
        student ??= await AttendanceRepository.instance
            .registerStudentFromAuthProfile(reg, fast: true);
      }
      if (!mounted) return;
      if (student == null) {
        final blocked = await AttendanceRepository.instance
            .deviceRegistrationBlockReason(reg);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              blocked ??
                  'Could not load your registered name. Sign in again and retry.',
            ),
          ),
        );
        return;
      }
      final studentRecord = student;
      ({AttendanceSession? session, AttendanceList? list}) resolved;
      try {
        resolved = await resolveFuture.timeout(networkBudget);
      } catch (_) {
        final fallbackSession =
            localSession ?? AttendanceRepository.instance.validateSessionCode(rawCode);
        AttendanceList? fallbackList;
        if (fallbackSession != null) {
          fallbackList = await _resolveListForKnownSession(fallbackSession);
        }
        resolved = (
          session: fallbackSession,
          list: fallbackList,
        );
      }
      var session = resolved.session;
      var list = resolved.list;
      if (session != null && list == null) {
        list = await _resolveListForKnownSession(session);
      }
      if (!mounted) return;
      if (session == null) {
        if (isOnline &&
            await AttendanceRepository.instance
                .serverHasOnlyInactiveSessionForCode(rawCode)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'This join code matches a session that has already ended. '
                'Ask your lecturer for the current code on screen.',
              ),
              duration: Duration(seconds: 7),
            ),
          );
          return;
        }
        final normalizedCode = normalizeSessionCodeInput(rawCode);
        final choice = await showUnknownSessionCodeConfirmDialog(
          context: context,
          normalizedCode: normalizedCode,
          isOnline: isOnline,
        );
        if (!mounted || choice == null) return;

        if (choice == UnknownSessionCodeConfirmChoice.codeIsWrong) {
          _returnToEnterNewSessionCode();
          return;
        }

        final saved = await _queueOfflineSessionAttempt(
          registrationNumber: reg,
          rawCode: rawCode,
        );
        if (!mounted) return;
        if (!saved) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isOnline
                  ? 'Code $normalizedCode saved for up to 7 days — '
                      'will auto-verify when your lecturer starts the session.'
                  : 'Code $normalizedCode saved for up to 7 days — '
                      'check-in will verify when the session is available.',
            ),
            duration: const Duration(seconds: 6),
          ),
        );
        return;
      }
      if (list == null && session != null) {
        list = await _resolveListForKnownSession(session);
      }
      if (list == null) {
        final refetched = await AttendanceRepository.instance
            .resolveSessionAndListForStudentCode(rawCode);
        session ??= refetched.session;
        list = refetched.list ?? (session != null
            ? await _resolveListForKnownSession(session)
            : null);
      }
      if (list == null) {
        await _queueOfflineSessionAttempt(
          registrationNumber: reg,
          rawCode: rawCode,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isOnline
                  ? 'Could not load this class list yet. Your code is saved and will verify when the session syncs.'
                  : 'Could not load this class list right now. Your attempt is saved and will auto-submit when synced.',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
        return;
      }
      final activeList = list;
      final checkInSession = session;
      if (checkInSession == null) return;
      if (AttendanceStore.isPresentForSession(checkInSession.id, studentRecord.id)) {
        if (!mounted) return;
        _clearSessionCodeAfterUse();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You already checked in for this session.'),
          ),
        );
        return;
      }
      var studentCourse = AttendanceStore.signedInCourseForStudentOnList(
          activeList.id, studentRecord.id);
      if (studentCourse == null || studentCourse.trim().isEmpty) {
        String? chosenCourse;
        if (activeList.coursesSafe.length > 1) {
          chosenCourse = await _pickCourseForFirstListSignIn(
            activeList,
            studentId: studentRecord.id,
          );
          if (!mounted) return;
          if (chosenCourse == null || chosenCourse.trim().isEmpty) {
            if (activeList.coursesSafe.isNotEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Choose a course from the list to continue.'),
                ),
              );
            }
            return;
          }
          chosenCourse = chosenCourse.trim();
        }
        final enroll = await AttendanceRepository.instance
            .ensureStudentEnrolledOnList(
          list: activeList,
          student: studentRecord,
          course: chosenCourse,
          excludeSessionIdFromMetadataPromotion: checkInSession.id,
          deferHeavyWork: true,
        );
        if (!mounted) return;
        switch (enroll) {
          case StudentListEnrollOutcome.deviceBlocked:
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'This device already registered another student. '
                  'Each phone may only be used for one student.',
                ),
                duration: Duration(seconds: 6),
              ),
            );
            return;
          case StudentListEnrollOutcome.noCourses:
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'This class list has no courses. Ask staff to add courses, then retry.',
                ),
                duration: Duration(seconds: 6),
              ),
            );
            return;
          case StudentListEnrollOutcome.needsCourseChoice:
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Choose a course from the list to continue.'),
              ),
            );
            return;
          case StudentListEnrollOutcome.alreadyEnrolled:
          case StudentListEnrollOutcome.enrolled:
            studentCourse = AttendanceStore.signedInCourseForStudentOnList(
                  activeList.id, studentRecord.id) ??
                chosenCourse ??
                (activeList.coursesSafe.length == 1
                    ? activeList.coursesSafe.first
                    : null);
            if (studentCourse == null || studentCourse.trim().isEmpty) {
              return;
            }
            studentCourse = studentCourse.trim();
        }
      } else {
      }
      if (!mounted) return;
      var activeSession = checkInSession;
      if (!activeSession.isOpenForCheckIn) {
        final refreshed = await AttendanceRepository.instance
            .resolveActiveSessionByCodeForSignIn(rawCode);
        if (refreshed != null && refreshed.isOpenForCheckIn) {
          activeSession = refreshed;
        }
      }
      if (!activeSession.isOpenForCheckIn) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'This session is no longer active. Ask your lecturer for a new code.',
            ),
          ),
        );
        return;
      }
      final installDeviceId = await DeviceIdentity.resolve();
      if (!mounted) return;
      if (installDeviceId.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not identify this device. Attendance cannot be saved.',
            ),
          ),
        );
        return;
      }
      final alreadyPresent =
          AttendanceStore.isPresentForSession(activeSession.id, studentRecord.id);
      if (!alreadyPresent &&
          await AttendanceRepository.instance.isDeviceBlockedForStudentSession(
            sessionId: activeSession.id,
            studentId: studentRecord.id,
            deviceId: installDeviceId,
            sessionCodeRaw: activeSession.sessionCode,
          )) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              userMessageForCheckInOutcome(
                StudentOfflineCheckInOutcome.deviceBlocked,
              ),
            ),
            duration: const Duration(seconds: 6),
          ),
        );
        return;
      }
      final prefetchedPosition = StudentLocationPriming.instance.lastPosition;
      FocusScope.of(context).unfocus();
      final result =
          await Navigator.of(context).push<StudentCheckInProgressResult>(
        MaterialPageRoute(
          builder: (ctx) => StudentCheckInProgressScreen(
            session: activeSession,
            student: studentRecord,
            list: activeList,
            selectedCourse: studentCourse,
            prefetchedPosition: prefetchedPosition,
          ),
        ),
      );
      if (!mounted) return;
      if (result != null && result.success) {
        unawaited(
          AttendanceRepository.instance.notifyAttendanceAfterCheckIn(
            sessionId: activeSession.id,
            studentId: studentRecord.id,
            listId: activeList.id,
          ),
        );
        final rec = AttendanceStore.attendanceRecordForSessionStudent(
          activeSession.id,
          studentRecord.id,
        );
        var course = rec?.course ?? '';
        if (course.isEmpty) {
          course = AttendanceStore.courseForStudentOnList(
            activeList.id,
            studentRecord.id,
          );
        }
        if (course.isEmpty && activeList.coursesSafe.isNotEmpty) {
          course = activeList.coursesSafe.first;
        }
        if (course.isEmpty) course = '—';
        unawaited(
          AttendanceRepository.instance.ensureSignInAndBackfillPastAbsents(
            listId: activeList.id,
            studentId: studentRecord.id,
            course: course,
            excludeSessionIdFromMetadataPromotion: activeSession.id,
          ).then((_) {
            unawaited(
              AttendanceRtdRecordWatch.instance.primeAfterStudentCheckIn(
                sessionId: activeSession.id,
                studentId: studentRecord.id,
                listId: activeList.id,
              ),
            );
            AttendanceRepository.instance.notifyStoreUpdatedFromRtd();
          }),
        );
        if (!mounted) return;
        setState(() {
          _currentStudent = studentRecord;
          if (!_registrationFieldLocked) {
            _regC.clear();
          }
        });
        _clearSessionCodeAfterUse();
        final codeLabel = activeSession.sessionCode.trim();
        final online = AppConnectivity.instance.isOnline;
        final pct = result.listAttendancePercent;
        final snackText = result.wasQueued
            ? 'Session $codeLabel saved on this device — will verify when you\'re back online.'
            : result.serverVerified
                ? online || pct == null
                    ? 'You are marked present for session $codeLabel.'
                    : 'Present for session $codeLabel. Your attendance for this class is $pct%.'
                : 'Check-in for session $codeLabel recorded — syncing official attendance.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(snackText),
            duration: Duration(seconds: result.wasQueued ? 7 : 5),
            action: result.wasQueued
                ? SnackBarAction(
                    label: 'Pending',
                    onPressed: () => unawaited(_openOfflinePendingScreen()),
                  )
                : null,
          ),
        );
      }
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _openOfflinePendingScreen() async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const PendingSessionsScreen(),
      ),
    );
  }

  Future<bool> _queueOfflineSessionAttempt({
    required String registrationNumber,
    required String rawCode,
  }) async {
    // Capture intent time before GPS — a slow fix must not push [capturedAt]
    // past [session.endTime] when we validate later with [resolveSessionByCodeAtTime].
    final captureIntentAt = DateTime.now();
    final id =
        '${normalizeSessionCodeInput(rawCode)}_${registrationNumber.trim().toUpperCase()}';

    final deviceId = await DeviceIdentity.resolve();
    if (!mounted) return false;
    if (deviceId.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not identify this device for offline queueing.'),
        ),
      );
      return false;
    }

    final pendingEntry = PendingSessionCodeEntry(
      id: id,
      registrationNumber: registrationNumber.trim().toUpperCase(),
      sessionCodeRaw: rawCode.trim(),
      capturedAt: captureIntentAt,
      latitude: 0,
      longitude: 0,
      deviceId: deviceId.trim(),
      status: PendingSessionCodeStatus.queued,
      note: '',
    );
    final deviceBlock = await PendingSessionCodeClaimUpload.localDeviceBlockReason(
      pendingEntry,
    );
    if (!mounted) return false;
    if (deviceBlock != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(deviceBlock),
          duration: const Duration(seconds: 6),
        ),
      );
      return false;
    }

    FocusScope.of(context).unfocus();
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => OfflineQueueLocationScreen(
          id: id,
          registrationNumber: registrationNumber,
          rawCode: rawCode,
          captureIntentAt: captureIntentAt,
          deviceId: deviceId.trim(),
        ),
      ),
    );
    if (!mounted) return false;
    if (ok == true) {
      _clearSessionCodeAfterUse();
      return true;
    }
    return false;
  }

  Future<void> _pullToRefresh() async {
    await widget.onRefresh();
    if (!mounted) return;
    _syncRegistrationFromProfile();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return PullToRefreshBody(
      onRefresh: _pullToRefresh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              child: ListenableBuilder(
                listenable: StudentLocationPriming.instance,
                builder: (context, _) {
                  final priming = StudentLocationPriming.instance;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Enter the join code from class ($kSessionJoinCodeFormatHint), then tap the arrow to submit. Location is prepared in the background.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textSecondary,
                              height: 1.35,
                            ),
                      ),
                      const SizedBox(height: 14),
                      LocationResolvingPanel(
                        compact: true,
                        resolving: priming.resolving,
                        position: priming.lastPosition,
                        errorMessage: priming.errorMessage,
                        locationServiceDisabled: priming.locationServiceDisabled,
                        permissionBlocked: priming.permissionBlocked,
                        onRetry: () => unawaited(
                          StudentLocationPriming.instance
                              .acquireFreshForCheckIn(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        controller: _regC,
                        readOnly: _registrationFieldLocked,
                        enableInteractiveSelection: !_registrationFieldLocked,
                        decoration: InputDecoration(
                          labelText: 'Registration number',
                          hintText: _registrationFieldLocked
                              ? null
                              : StudentRegistrationNumber.example,
                          suffixIcon: _registrationFieldLocked
                              ? Icon(Icons.lock_outline_rounded,
                                  color: AppTheme.textSecondary, size: 20)
                              : null,
                        ),
                        textCapitalization: TextCapitalization.characters,
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _sessionCodeC,
                        focusNode: _sessionCodeFocus,
                        decoration: InputDecoration(
                          labelText: 'Session code',
                          hintText: kSessionJoinCodeExample,
                          helperText: kSessionJoinCodeFormatHint,
                          counterText: '',
                          suffixIcon: _sessionCodeSubmitSuffix(),
                        ),
                        textCapitalization: TextCapitalization.characters,
                        maxLength: 4,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.done,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[A-Za-z0-9]'),
                          ),
                          LengthLimitingTextInputFormatter(4),
                        ],
                        onChanged: _onStudentSessionCodeChanged,
                        onFieldSubmitted: (_) {
                          if (_canSubmitSessionCode) {
                            unawaited(_continueToCheckIn());
                          }
                        },
                      ),
                      if (_busy) ...[
                        const SizedBox(height: 12),
                        Text(
                          _studentBusyButtonLabel(),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppTheme.textSecondary,
                              ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const PendingSessionsScreen(),
                              ),
                            );
                            if (mounted) setState(() {});
                          },
                          icon: const Icon(Icons.pending_actions_rounded),
                          label: const Text('Check-ins'),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
