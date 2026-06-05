import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/auth/student_registration_number.dart';
import '../../core/firebase/firestore_collections.dart';
import '../../core/firebase/u_panel_firestore.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/device/device_identity.dart';
import '../../core/theme/app_theme.dart';
import '../../core/location/location_permission.dart';
import 'models/attendance_models.dart';
import 'assigned_lecturer_field.dart';
import 'attendance_list_hierarchy.dart';
import 'data/attendance_repository.dart';
import 'data/attendance_offline_sync.dart';
import 'pending_sessions_screen.dart';
import 'student_check_in_progress_screen.dart';
import 'offline_queue_location_screen.dart';
import 'attendance_top_feedback.dart';
import 'attendance_list_title.dart';
import 'qa_program_session_ui.dart';

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
    final uid = a.currentFirebaseUid;
    if (uid == null || uid.isEmpty) return false;
    return attendanceListAccessibleToLecturer(list, uid);
  }
  return false;
}

/// Sign-in flows: cap Firestore wait so offline / flaky Wi‑Fi still reaches queue paths.
Future<void> _loadAttendanceStoreForSignIn() async {
  final online = AppConnectivity.instance.isOnline;
  final d = online ? const Duration(seconds: 12) : const Duration(seconds: 10);
  try {
    await AttendanceRepository.instance.loadAll().timeout(d);
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
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loading = !AttendanceRepository.instance.hasCachedStore;
    unawaited(_load());
  }

  static const Duration _loadTimeout = Duration(seconds: 8);

  Future<void> _load({bool force = false}) async {
    final blocking = !AttendanceRepository.instance.hasCachedStore;
    if (blocking) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      await _waitForAuthRoleHydration();
      final scope = AttendanceRepository.currentLecturerLoadScopeUid();
      await AttendanceRepository.instance
          .loadAll(
            force: force,
            scopeToLecturerUid: scope,
          )
          .timeout(
        _loadTimeout,
          onTimeout: () {
        throw TimeoutException('Load timed out', _loadTimeout);
      },
      );
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
          _loadError = null;
          // Show UI with local/empty data so attendance works without Firebase.
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 400;
    final auth = AuthRepository.instance;

    // Always show layout immediately; only content area shows loading or error.
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        final canQa = auth.adminCheckDone && auth.isAdmin;
        final canActAsStaff = canQa ||
            (auth.lecturerCheckDone && auth.isLecturer);
        // QA staff and lecturers use attendance management UI here.
        final studentFlow = !canActAsStaff;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context, narrow, studentFlow),
            Expanded(
              child: studentFlow
                  ? const SingleChildScrollView(
                      child: _SignInContent(),
                    )
                  : _loading &&
                          !AttendanceRepository.instance.hasCachedStore
                      ? const Center(child: CircularProgressIndicator())
                      : _loadError != null
                          ? SingleChildScrollView(
                              child: Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
    );
  }

  Widget _buildHeader(BuildContext context, bool narrow, bool isStudent) {
    final title = isStudent ? 'Sign in' : 'Attendance';
    final subtitle = isStudent
        ? 'Enter your registration number and the class session code from your lecturer.'
        : 'Create lists · Start sessions · Students sign in with their account, then session code to check in';

    if (narrow) {
      return Column(
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
                              value: '${listSessions.length}',
                              label: listSessions.length == 1
                                  ? 'session'
                                  : 'sessions',
                            ),
                            _ListStatPill(
                              icon: Icons.fact_check_outlined,
                              value: '$rollRows',
                              label: rollRows == 1 ? 'row' : 'rows',
                            ),
                            _ListStatPill(
                              icon: Icons.groups_outlined,
                              value: '$rosterCount',
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
  const AttendanceDayProgramsScreen({super.key, required this.weekday});

  final int weekday;

  @override
  Widget build(BuildContext context) {
    final allLists = attendanceListsForCurrentStaff();
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
        title: Text(dayLabel),
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
  });

  final int weekday;
  final AttendanceProgram program;

  @override
  State<AttendanceProgramListsScreen> createState() =>
      _AttendanceProgramListsScreenState();
}

class _AttendanceProgramListsScreenState
    extends State<AttendanceProgramListsScreen> {
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
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => StartSessionScreen(
          list: list,
          resumeSession: resume,
        ),
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
      allowListMaintenance: attendanceListAllowsMaintenance(list),
      onOpenDetail: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (ctx) => SessionCheckInsScreen(list: list),
          ),
        );
      },
      onHistory: () {
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
    final lists = listsForWeekdayAndProgram(
      attendanceListsForCurrentStaff(),
      widget.weekday,
      widget.program,
    );
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
        title: Text('$dayLabel · ${widget.program.label}'),
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
        onRefresh: () async {
          await AttendanceRepository.instance.loadAll(
            force: true,
            scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
          );
          if (mounted) setState(() {});
        },
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
    final attendanceLists = attendanceListsForCurrentStaff();

    final narrow = MediaQuery.of(context).size.width < 500;
    return SingleChildScrollView(
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
              ),
            )
          else
            FilledButton.icon(
              onPressed: _openCreateScreen,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('Create attendance list'),
            ),
          const SizedBox(height: 22),
          Container(
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
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 0.12),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha: 0.06),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
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
                        Icons.layers_rounded,
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
                            'Class days',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Monday through Sunday — pick a day, then Day, Evening, or Weekend program (weekend only Sat–Sun).',
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
              ],
            ),
          ),
          const SizedBox(height: 16),
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
  Future<void> _reload() async {
    await AttendanceRepository.instance.loadAll(
      force: true,
      scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
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
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _reload,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: sessions.isEmpty
          ? const Center(
              child:
                  Text('No sessions yet. Start one from the attendance list.'),
            )
          : ListView.builder(
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
  AttendanceSession? _startedSession;

  static const List<double> _radiusOptions = [25, 50, 100, 150, 1500];
  static const List<int> _durationOptions = [1, 2, 10, 15, 20];

  bool get _lecturerOnly {
    final auth = AuthRepository.instance;
    return auth.lecturerCheckDone && auth.isLecturer && !auth.isAdmin;
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
      final uid = auth.currentFirebaseUid?.trim();
      if (uid != null && uid.isNotEmpty) {
        try {
          final snap = await uPanelFirestore()
              .collection(FirestoreCollections.lecturers)
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
    if (_createdByC.text.trim().isEmpty) {
      await _resolveLecturerCreatedBy();
    }
    final fromField = _createdByC.text.trim();
    if (fromField.isNotEmpty) return fromField;
    final auth = AuthRepository.instance;
    final staff = auth.currentStaffNumber?.trim();
    if (staff != null && staff.isNotEmpty) return staff;
    final email = auth.currentEmail?.trim();
    if (email != null && email.isNotEmpty) return email;
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
        unawaited(_prefetchLocationQuietly());
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

  /// Warms last-known GPS without blocking the start button (fast offline starts).
  Future<void> _prefetchLocationQuietly() async {
    if (_position != null) return;
    final quick = await quickPositionForSessionStart();
    if (!mounted || quick == null) return;
    setState(() {
      _position = quick;
      _locationError = null;
    });
    if (AppConnectivity.instance.isOnline) {
      unawaited(_refineLocationInBackground());
    }
  }

  Future<void> _refineLocationInBackground() async {
    final r = await tryAcquireGpsPosition(
      timeLimit: const Duration(seconds: 12),
    );
    if (!mounted || r.position == null) return;
    setState(() {
      _position = r.position;
      _locationError = null;
    });
  }

  Future<void> _getLocation() async {
    setState(() => _locationError = null);
    final quick = await quickPositionForSessionStart();
    if (quick != null) {
      if (!mounted) return;
      setState(() {
        _position = quick;
        _locationError = null;
      });
      if (AppConnectivity.instance.isOnline) {
        unawaited(_refineLocationInBackground());
      }
      return;
    }
    final r = await tryAcquireGpsPosition(
      timeLimit: AppConnectivity.instance.isOnline
          ? const Duration(seconds: 15)
          : const Duration(seconds: 8),
    );
    if (!mounted) return;
    setState(() {
      if (r.position != null) {
        _position = r.position;
        _locationError = null;
      } else {
        _locationError = r.errorMessage ??
            'Could not read your location. Tap "Use current location" to retry.';
      }
    });
  }

  Future<Position?> _resolvePositionForSessionStart() async {
    if (_position != null) return _position;
    final quick = await quickPositionForSessionStart();
    if (quick != null) return quick;
    final r = await tryAcquireGpsPosition(
      timeLimit: AppConnectivity.instance.isOnline
          ? const Duration(seconds: 12)
          : const Duration(seconds: 5),
    );
    return r.position;
  }

  Future<void> _startSession() async {
    if (_starting) {
      return;
    }

    final createdBy = await _sessionCreatedByForStart();
    if (!_lecturerOnly && createdBy.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter your name (QA officer)')));
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

    setState(() => _starting = true);
    try {
      double latitude;
      double longitude;
      if (_remoteLearning) {
        latitude = _position?.latitude ?? 0;
        longitude = _position?.longitude ?? 0;
      } else {
        final position = await _resolvePositionForSessionStart();
        if (!mounted) {
          return;
        }
        if (position == null) {
          final msg = _locationError ??
              'Turn on GPS, allow location for U-Panel, then tap "Use current location".';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), duration: const Duration(seconds: 6)),
          );
          return;
        }
        setState(() {
          _position = position;
          _locationError = null;
        });
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
      if (!created.syncedToServer) {
        unawaited(_refineLocationInBackground());
      }
      if (!created.syncedToServer) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Session saved on this device. It will publish to the server when you are back online.',
            ),
            duration: Duration(seconds: 6),
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
                    'Students must be within the radius of this GPS point when they enter the join code.',
              ),
              const SizedBox(height: 12),
            ] else ...[
              const SizedBox(height: 20),
              const QaInfoCallout(
                text:
                    'Long-distance mode: students can check in from anywhere. '
                    'They still need the join code and must sign in during the session window.',
              ),
              const SizedBox(height: 12),
            ],
            if (!_remoteLearning)
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
                alignment: Alignment.centerLeft,
                side: BorderSide(
                  color: AppTheme.primary.withValues(alpha: 0.35),
                ),
              ),
              onPressed: _getLocation,
              icon: Icon(
                _position == null
                    ? Icons.location_searching_rounded
                    : Icons.location_on_rounded,
                size: 22,
                color: AppTheme.primary,
              ),
              label: Text(
                _position == null
                    ? 'Use current GPS location'
                    : '${_position!.latitude.toStringAsFixed(5)}, ${_position!.longitude.toStringAsFixed(5)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ),
            if (!_remoteLearning && _locationError != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.error.withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        color: AppTheme.error, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _locationError!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppTheme.error,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 22),
            QaInfoCallout(
              text: _remoteLearning
                  ? 'When you start, the app creates a unique 3-digit join code. '
                      'Share it with remote students yourself (no automatic push). '
                      'Students: Sign in → Session code → enter those three digits, then Continue.'
                  : 'When you start, the app creates a unique 3-digit join code. '
                      'Students: Sign in → Session code → enter those three digits (not their personal 3-digit student code), then Continue. Time and location are checked automatically.',
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
                  _starting
                      ? 'Creating session & code…'
                      : 'Start session & show join code',
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
  Timer? _expiryTimer;
  bool _closing = false;
  bool _autoEndPending = false;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoEndExpired();
      _scheduleExpiryAutoClose();
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _maybeAutoEndExpired();
      setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _expiryTimer?.cancel();
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
          'The join code will stop working. Anyone on this list’s roster who did '
          'not check in will be marked absent so attendance percentages stay accurate.',
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
    final remaining = session.endTime.difference(DateTime.now());
    final minsLeft = remaining.isNegative ? 0 : remaining.inMinutes;
    final secsPart =
        remaining.isNegative ? 0 : remaining.inSeconds.remainder(60);
    final expired = session.isExpired;

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
                color: (expired ? AppTheme.warning : AppTheme.success)
                    .withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: (expired ? AppTheme.warning : AppTheme.success)
                      .withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    expired ? Icons.hourglass_bottom_rounded : Icons.sensors_rounded,
                    size: 18,
                    color: expired ? AppTheme.warning : AppTheme.success,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      expired
                          ? 'Time elapsed — finalizing and closing…'
                          : session.remoteLearning
                              ? 'Live · long-distance (no location check)'
                              : 'Live session · join code active',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: expired ? AppTheme.warning : AppTheme.success,
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
                  : 'Students: Sign in → Session code → enter this code, then location check.',
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
                      minsLeft > 0
                          ? 'Time left: $minsLeft min ${secsPart.toString().padLeft(2, '0')} sec'
                          : 'Ending soon (${secsPart.toString().padLeft(2, '0')}s)',
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
            Builder(
              builder: (context) {
                final recs = AttendanceStore.recordsForSession(session.id);
                final present = recs.where((r) => r.present).length;
                final absent = recs.where((r) => !r.present).length;
                return Text(
                  '$present present · $absent absent · ${recs.length} roll row(s)',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleSmall,
                );
              },
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
  Future<void> _refresh() async {
    await AttendanceRepository.instance.loadAll(
      force: true,
      scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
    );
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppConnectivity.instance.addListener(_onConnectivity);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppConnectivity.instance.removeListener(_onConnectivity);
    super.dispose();
  }

  void _onConnectivity() {
    if (!AppConnectivity.instance.isOnline) return;
    unawaited(
      AttendanceOfflineSync.drainAllInOrder().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final studentsById = <String, StudentRecord>{
      for (final s in AttendanceStore.students) s.id: s,
    };
    final listSessions = AttendanceStore.sessions
        .where((s) => s.listId == widget.list.id)
        .toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    final listSessionIds = listSessions.map((s) => s.id).toSet();
    final listRecords = AttendanceStore.attendanceRecords
        .where((r) => listSessionIds.contains(r.sessionId))
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final studentIds = <String>{
      ...AttendanceStore.studentIdsSignedIntoList(widget.list.id),
      ...listRecords.map((r) => r.studentId),
    };
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Roll · consolidated'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      body: rollKeys.isEmpty
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
                      final student = studentsById[sid];
                      final name = student?.name ?? 'Unknown';
                      final reg = student?.registrationNumber ?? '—';
                      final rows =
                          rollRowsByKey[k] ?? const <AttendanceRecord>[];
                      // Merge duplicate session rows (e.g. same reg, two student
                      // ids): any present wins. Matches [rollStatsForRegistrationNormalized].
                      final statusesBySessionId = <String, String>{};
                      for (final r in rows) {
                        final next = r.present ? 'Present' : 'Absent';
                        final prev = statusesBySessionId[r.sessionId];
                        statusesBySessionId[r.sessionId] =
                            (prev == 'Present' || next == 'Present')
                                ? 'Present'
                                : 'Absent';
                      }
                      // Completed sessions with no row = absent (same as profile %).
                      // In-progress sessions: no row yet → em dash, not absent.
                      String? cellLabelForSession(AttendanceSession s) {
                        final fromRow = statusesBySessionId[s.id];
                        if (fromRow != null) {
                          return fromRow;
                        }
                        if (s.countsTowardRollStats) {
                          return 'Absent';
                        }
                        return null;
                      }

                      final rateSessions = listSessions
                          .where((s) => s.countsTowardRollStats)
                          .toList();
                      var presentForRate = 0;
                      for (final s in rateSessions) {
                        if (cellLabelForSession(s) == 'Present') {
                          presentForRate++;
                        }
                      }
                      final totalRate = rateSessions.length;
                      final percent = totalRate <= 0
                          ? '0%'
                          : '${((100 * presentForRate) / totalRate).round().clamp(0, 100)}%';

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
                                  } else if (label == 'Present') {
                                    color = AppTheme.primary;
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
      final uid = auth.currentFirebaseUid?.trim();
      if (uid != null && uid.isNotEmpty) {
        try {
          final snap = await uPanelFirestore()
              .collection(FirestoreCollections.lecturers)
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
    final auth = AuthRepository.instance;
    final creatorUid = auth.currentFirebaseUid?.trim();
    String? lecturerUid;
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
    } else if (auth.isLecturer && auth.lecturerCheckDone) {
      lecturerUid = auth.currentFirebaseUid;
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
      await AttendanceRepository.instance.addList(list);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Attendance list "$courseUnit" created')),
      );
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
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                      ),
                      const SizedBox(height: 16),
                      _field(_whoTaughtC, 'Name of lecturer / Who taught',
                          'e.g. Dr. Smith', TextInputType.name),
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
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppTheme.textSecondary,
                              ),
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
                                _field(_roomC, 'Room', 'e.g. A101',
                                    TextInputType.text),
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
                                  child: _field(_roomC, 'Room', 'e.g. A101',
                                      TextInputType.text)),
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
                          );
                          final semDropdown = DropdownButtonFormField<String>(
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
                                child: _field(e.courseC, 'Course',
                                    'e.g. CS 101', TextInputType.text),
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
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.check_rounded, size: 20),
                        label: Text(_saving ? 'Saving...' : 'Add to list'),
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
      final snap = await uPanelFirestore()
          .collection(FirestoreCollections.lecturers)
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
      lecturerUid = resolved.uid;
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

/// When a registration is missing from the roster, collect name and add them.
class _JoinRosterDialog extends StatefulWidget {
  const _JoinRosterDialog({required this.registrationNumber});
  final String registrationNumber;

  @override
  State<_JoinRosterDialog> createState() => _JoinRosterDialogState();
}

class _JoinRosterDialogState extends State<_JoinRosterDialog> {
  final _nameC = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _nameC.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameC.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your full name.')),
      );
      return;
    }
    final ini = initialsFromFullName(name);
    setState(() => _busy = true);
    try {
      final student = await AttendanceRepository.instance.registerStudent(
        name,
        widget.registrationNumber,
        ini,
      );
      if (!mounted) return;
      Navigator.of(context).pop(student);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New student profile'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Registration ${widget.registrationNumber} is not on this device yet. '
              'Add your name once to create your student profile. '
              'On the next step you will pick your course for the class you are checking into.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameC,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Full name',
                hintText: 'As registered with the university',
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Add & continue'),
        ),
      ],
    );
  }
}

/// Student sign-in: registration number + session code.
class _SignInContent extends StatefulWidget {
  const _SignInContent();

  @override
  State<_SignInContent> createState() => _SignInContentState();
}

class _SignInContentState extends State<_SignInContent> {
  final _regC = TextEditingController();
  final _sessionCodeC = TextEditingController();
  bool _busy = false;

  /// Upper-bound hint while Firestore / GPS work; ticks down once per second.
  static const int _signInBusyCountdownSeconds = 35;
  Timer? _busyCountdownTimer;
  int _busyCountdownRemaining = 0;

  StudentRecord? _currentStudent;

  /// When true, registration came from the signed-in profile and cannot be edited.
  bool _regFromProfile = false;

  void _syncRegistrationFromProfile() {
    final r = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (r != null && r.isNotEmpty) {
      if (_regC.text != r) {
        _regC.text = r;
      }
      if (!_regFromProfile) {
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
    final student = AttendanceStore.findStudentByReg(r);
    if (_currentStudent?.id != student?.id) {
      setState(() => _currentStudent = student);
    }
  }

  @override
  void initState() {
    super.initState();
    AuthRepository.instance.addListener(_syncRegistrationFromProfile);
    AppConnectivity.instance.addListener(_onConnectivityChanged);
    _syncRegistrationFromProfile();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(AttendanceOfflineSync.drainAllInOrder().then((_) {
        if (mounted) setState(() {});
      }));
    });
  }

  @override
  void dispose() {
    _busyCountdownTimer?.cancel();
    AppConnectivity.instance.removeListener(_onConnectivityChanged);
    AuthRepository.instance.removeListener(_syncRegistrationFromProfile);
    _regC.dispose();
    _sessionCodeC.dispose();
    super.dispose();
  }

  void _setBusy(bool value) {
    if (value) {
      _busyCountdownTimer?.cancel();
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
    final online = AppConnectivity.instance.isOnline;
    if (_busyCountdownRemaining > 0) {
      return online
          ? 'Checking… ${_busyCountdownRemaining}s'
          : 'Resolving… ${_busyCountdownRemaining}s';
    }
    return online ? 'Checking…' : 'Resolving…';
  }

  void _onConnectivityChanged() {
    if (!mounted) return;
    if (AppConnectivity.instance.isOnline) {
      unawaited(AttendanceOfflineSync.drainAllInOrder());
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
    final normalized = normalizeSessionCodeInput(_sessionCodeC.text);
    if (_busy) return;
    if (_regC.text.trim().isEmpty) return;
    if (!isValidJoinCodeFormat(normalized)) return;
    unawaited(_continueToCheckIn());
  }

  Future<void> _showAuthVerificationAnimation() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const _AuthVerificationDialog(),
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
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
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
                        child: Text(course),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  bool get _registrationFormatOk =>
      StudentRegistrationNumber.validateFormat(_regC.text) == null;

  Future<void> _continueToCheckIn() async {
    final regErr = StudentRegistrationNumber.validateFormat(_regC.text);
    if (regErr != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(regErr)),
      );
      return;
    }
    final reg = StudentRegistrationNumber.normalize(_regC.text);
    final rawCode = _sessionCodeC.text.trim();
    if (!isValidJoinCodeFormat(normalizeSessionCodeInput(rawCode))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text(
                    'Enter the session code from your class (3 digits on screen).')),
      );
      return;
    }
    await _showAuthVerificationAnimation();
    if (!mounted) return;
    _setBusy(true);
    try {
      final isOnline = AppConnectivity.instance.isOnline;

      // Always refresh store when possible (Firestore cache works offline too).
      // Skipping load while offline made existing students look "new" and caused
      // duplicate profiles / wrong Join-roster prompts. Capped wait keeps UI fast.
      await _loadAttendanceStoreForSignIn();
      if (!mounted) return;
      late final StudentRecord student;
      final existing = AttendanceStore.findStudentByReg(reg);
      if (existing != null) {
        student = existing;
      } else {
        final added = await showDialog<StudentRecord>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => _JoinRosterDialog(registrationNumber: reg.trim()),
        );
        if (!mounted) return;
        if (added == null) {
          return;
        }
        student = added;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Profile saved. Next, pick your course for this class if asked.'),
            ),
          );
        }
      }
      var session = AttendanceRepository.instance.validateSessionCode(rawCode);
      if (session == null && isOnline) {
        try {
          session = await AttendanceRepository.instance
              .resolveSessionByCode(rawCode)
              .timeout(const Duration(seconds: 8));
        } catch (_) {
          session = null;
        }
      }
      if (!mounted) return;
      if (session == null) {
        if (isOnline) {
          AttendanceSession? latestForCode;
          try {
            latestForCode = await AttendanceRepository.instance
                .resolveLatestSessionByCode(rawCode)
                .timeout(const Duration(seconds: 8));
          } catch (_) {
            latestForCode = null;
          }
          if (!mounted) return;
          if (latestForCode != null) {
            await _queueOfflineSessionAttempt(
              registrationNumber: reg,
              rawCode: rawCode,
            );
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'This code looks expired now, but your attempt is saved and will be auto-rechecked.',
                ),
              ),
            );
            return;
          }
          await _queueOfflineSessionAttempt(
            registrationNumber: reg,
            rawCode: rawCode,
          );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Code not found right now. Your attempt is saved and will auto-compare when sync succeeds.',
              ),
            ),
          );
          return;
        }
        // If we cannot resolve now (including flaky online->offline transitions),
        // keep the attempt and auto-validate/submit when data is reachable again.
        await _queueOfflineSessionAttempt(
          registrationNumber: reg,
          rawCode: rawCode,
        );
        return;
      }
      var list = AttendanceStore.listById(session.listId);
      if (list == null) {
        try {
          list = await AttendanceRepository.instance
              .resolveListById(session.listId)
              .timeout(const Duration(seconds: 6));
        } catch (_) {
          list = null;
        }
      }
      if (list == null) {
        try {
          await AttendanceRepository.instance
              .loadAll(
                force: true,
                scopeToLecturerUid:
                    AttendanceRepository.currentLecturerLoadScopeUid(),
              )
              .timeout(const Duration(seconds: 12));
        } catch (_) {}
        list = AttendanceStore.listById(session.listId);
      }
      if (list == null) {
        // Wi‑Fi can report "online" while DNS/Firestore is unreachable — still
        // queue so the attempt appears under Offline pending sessions.
        await _queueOfflineSessionAttempt(
          registrationNumber: reg,
          rawCode: rawCode,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isOnline
                  ? 'Could not load this class list (network may be unstable). '
                      'Your attempt is saved and will retry when connection works.'
                  : 'Could not load this class list right now. Your attempt is saved and will auto-submit when synced.',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
        return;
      }
      final activeList = list;
      if (AttendanceStore.isPresentForSession(session.id, student.id)) {
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
          activeList.id, student.id);
      if (studentCourse == null || studentCourse.trim().isEmpty) {
        final chosen = await _pickCourseForFirstListSignIn(
          activeList,
          studentId: student.id,
        );
        if (!mounted) return;
        if (chosen == null || chosen.trim().isEmpty) {
          if (activeList.coursesSafe.isNotEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Choose a course from the list to continue.'),
              ),
            );
          }
          return;
        }
        studentCourse = chosen.trim();
        try {
          await AttendanceRepository.instance
              .ensureSignInAndBackfillPastAbsents(
            listId: activeList.id,
            studentId: student.id,
            course: studentCourse,
          );
        } catch (e) {
          if (!mounted) return;
          await _queueOfflineSessionAttempt(
            registrationNumber: reg,
            rawCode: rawCode,
          );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Could not save enrollment online ($e). '
                'If location was captured, your attempt is under Offline pending sessions; '
                'otherwise enable connection or GPS and try again.',
              ),
              duration: const Duration(seconds: 8),
            ),
          );
          return;
        }
      }
      if (!mounted) return;
      final result =
          await Navigator.of(context).push<StudentCheckInProgressResult>(
        MaterialPageRoute(
          builder: (ctx) => StudentCheckInProgressScreen(
            session: session!,
            student: student,
            list: activeList,
            selectedCourse: studentCourse,
          ),
        ),
      );
      if (!mounted) return;
      if (result != null && result.success) {
        if (result.wasQueued) {
          showAttendanceTopSuccessBanner(
            context,
            'Attendance saved on this device. It will upload when you are online.',
          );
          unawaited(_openOfflinePendingScreen());
        } else {
          showAttendanceTopSuccessBanner(
            context,
            'Check-in verified and saved for this session.',
          );
        }
        final rec = AttendanceStore.attendanceRecordForSessionStudent(
          session.id,
          student.id,
        );
        var course = rec?.course ?? '';
        if (course.isEmpty) {
          course =
              AttendanceStore.courseForStudentOnList(activeList.id, student.id);
        }
        if (course.isEmpty && activeList.coursesSafe.isNotEmpty) {
          course = activeList.coursesSafe.first;
        }
        if (course.isEmpty) course = '—';
        try {
          await AttendanceRepository.instance
              .ensureSignInAndBackfillPastAbsents(
            listId: activeList.id,
            studentId: student.id,
            course: course,
          );
        } catch (_) {}
        if (!mounted) return;
        setState(() {
          _currentStudent = student;
          if (!_regFromProfile) {
            _regC.clear();
          }
        });
        _clearSessionCodeAfterUse();
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

  Future<void> _queueOfflineSessionAttempt({
    required String registrationNumber,
    required String rawCode,
  }) async {
    // Capture intent time before GPS — a slow fix must not push [capturedAt]
    // past [session.endTime] when we validate later with [resolveSessionByCodeAtTime].
    final captureIntentAt = DateTime.now();
    final id =
        '${normalizeSessionCodeInput(rawCode)}_${registrationNumber.trim().toUpperCase()}';

    final deviceId = await DeviceIdentity.resolve();
    if (!mounted) return;
    if (deviceId.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not identify this device for offline queueing.'),
        ),
      );
      return;
    }

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
    if (!mounted) return;
    if (ok == true) {
      _clearSessionCodeAfterUse();
      showAttendanceTopSuccessBanner(
        context,
        'Session saved for later verification. It will auto-validate when you are online.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        await AttendanceRepository.instance.loadAll(
          scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
        );
        if (mounted) {
          _syncRegistrationFromProfile();
          setState(() {});
        }
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Enter your registration number and the live session code from your lecturer.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                            height: 1.35,
                          ),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _regC,
                      readOnly: _regFromProfile,
                      enableInteractiveSelection: !_regFromProfile,
                      decoration: InputDecoration(
                        labelText: 'Registration number',
                        hintText: _regFromProfile
                            ? null
                            : StudentRegistrationNumber.example,
                        suffixIcon: _regFromProfile
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
                      decoration: const InputDecoration(
                        labelText: 'Session code',
                        hintText: '3 digits from class',
                        counterText: '',
                      ),
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 4,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
                      ],
                      onChanged: _onStudentSessionCodeChanged,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : (!isValidJoinCodeFormat(normalizeSessionCodeInput(
                                      _sessionCodeC.text)) ||
                                  !_registrationFormatOk)
                              ? null
                              : _continueToCheckIn,
                      child: _busy
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(_studentBusyButtonLabel()),
                              ],
                            )
                          : const Text('Continue'),
                    ),
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
                        label: const Text('Offline pending sessions'),
                      ),
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

class _AuthVerificationDialog extends StatefulWidget {
  const _AuthVerificationDialog();

  @override
  State<_AuthVerificationDialog> createState() =>
      _AuthVerificationDialogState();
}

class _AuthVerificationDialogState extends State<_AuthVerificationDialog>
    with SingleTickerProviderStateMixin {
  static const _stagesOnline = <String>[
    'Securing your session…',
    'Checking account access…',
    'All set — opening check-in…',
  ];

  static const _stagesOffline = <String>[
    'Working on this device…',
    'Preparing offline-safe check-in…',
    'All set — opening check-in…',
  ];

  late final bool _startedOnline;
  late final AnimationController _pulse;
  int _stageIndex = 0;

  List<String> get _stages =>
      _startedOnline ? _stagesOnline : _stagesOffline;

  @override
  void initState() {
    super.initState();
    _startedOnline = AppConnectivity.instance.isOnline;
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _runSequence();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _runSequence() async {
    // Hold each step long enough to read; total ~2.4s before closing.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    setState(() => _stageIndex = 1);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    setState(() => _stageIndex = 2);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final modeLabel = _startedOnline ? 'Online' : 'Offline';
    final modeColor =
        _startedOnline ? AppTheme.primaryLight : AppTheme.warning;
    final modeBg = _startedOnline
        ? AppTheme.primary.withValues(alpha: 0.12)
        : AppTheme.warning.withValues(alpha: 0.14);

    return PopScope(
      canPop: false,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppTheme.surface,
                AppTheme.accentLight.withValues(alpha: 0.35),
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 58,
                      height: 58,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(2),
                            child: SizedBox(
                              width: 54,
                              height: 54,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: AppTheme.primary,
                                backgroundColor:
                                    AppTheme.accentLight.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                          FadeTransition(
                            opacity: Tween<double>(begin: 0.55, end: 1.0).animate(
                              CurvedAnimation(
                                parent: _pulse,
                                curve: Curves.easeInOut,
                              ),
                            ),
                            child: Icon(
                              _startedOnline
                                  ? Icons.verified_user_rounded
                                  : Icons.shield_moon_rounded,
                              size: 30,
                              color: AppTheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Verification',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Material(
                                color: modeBg,
                                borderRadius: BorderRadius.circular(999),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _startedOnline
                                            ? Icons.wifi_rounded
                                            : Icons.wifi_off_rounded,
                                        size: 15,
                                        color: modeColor,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        modeLabel,
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                          color: modeColor,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Text(
                                _startedOnline
                                    ? 'Syncing when the network is ready.'
                                    : 'Saved steps stay on this device until you reconnect.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textSecondary,
                                  height: 1.25,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 1750),
                    curve: Curves.easeOutCubic,
                    builder: (context, t, _) {
                      return LinearProgressIndicator(
                        minHeight: 6,
                        value: t,
                        backgroundColor:
                            AppTheme.softGrey.withValues(alpha: 0.85),
                        color: AppTheme.primary,
                      );
                    },
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: List.generate(3, (i) {
                    final done = _stageIndex > i;
                    final active = _stageIndex == i;
                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: i < 2 ? 8 : 0),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          height: 5,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            color: done
                                ? AppTheme.success
                                : active
                                    ? AppTheme.primary
                                    : AppTheme.softGrey,
                          ),
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 16),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  transitionBuilder: (child, anim) {
                    return FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.06),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    );
                  },
                  child: Align(
                    alignment: Alignment.centerLeft,
                    key: ValueKey<int>(_stageIndex),
                    child: Text(
                      _stages[_stageIndex],
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                        color: AppTheme.textPrimary,
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
  }
}
