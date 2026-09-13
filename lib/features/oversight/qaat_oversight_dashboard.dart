import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/auth/user_role.dart';
import '../../core/navigation/app_section.dart';
import '../../core/navigation/app_shell.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/models/attendance_models.dart';
import '../lesson_insights/qa_lesson_activity_screen.dart';
import 'oversight_metrics.dart';

/// QAAT leadership chrome — slate field, not the green ops dashboard.
abstract final class QaatVisuals {
  static const Color ink = Color(0xFF0F172A);
  static const Color slate = Color(0xFF1E293B);
  static const Color muted = Color(0xFF64748B);
  static const Color card = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFCBD5E1);
  static const Color eligible = Color(0xFF16A34A);
  static const Color ineligible = Color(0xFFDC2626);
  static const Color pending = Color(0xFFD97706);
  static const Color page = Color(0xFFE8EEF5);
  static const Color accent = Color(0xFF0F766E);
  static const Color banner = Color(0xFF0B1220);

  static BoxDecoration cardDecoration({bool alert = false}) => BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: alert ? ineligible : border,
          width: alert ? 2 : 1,
        ),
      );
}

class QaatOversightDashboard extends StatefulWidget {
  const QaatOversightDashboard({
    super.key,
    this.shellSection = AppSection.dashboard,
    this.embedded = false,
  });

  final AppSection shellSection;
  final bool embedded;

  @override
  State<QaatOversightDashboard> createState() => _QaatOversightDashboardState();
}

class _QaatOversightDashboardState extends State<QaatOversightDashboard> {
  bool _loading = true;
  bool _refreshing = false;
  AttendanceProgram? _program;
  OversightSnapshot _snap = OversightSnapshot.empty();

  UserRole get _role => AuthRepository.instance.resolvedRole;

  @override
  void initState() {
    super.initState();
    _loading = !AttendanceRepository.instance.hasCachedStore;
    unawaited(_refresh());
  }

  Future<void> _refresh({bool force = false}) async {
    await AttendanceRepository.instance.warmFromLocalSnapshot();
    if (!mounted) return;
    setState(() {
      _refreshing = force;
      if (!AttendanceRepository.instance.hasCachedStore) _loading = true;
    });
    try {
      if (force || !AttendanceRepository.instance.hasCachedStore) {
        await AttendanceRepository.instance.bootstrapLoadIfNeeded(force: force);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _snap = OversightMetrics.compute(program: _program);
      _loading = false;
      _refreshing = false;
    });
  }

  String get _title {
    switch (_role) {
      case UserRole.vc:
      case UserRole.dvc:
        return 'VC Overview';
      case UserRole.dqa:
        return 'Quality Assurance';
      case UserRole.dean:
        return 'Dean Overview';
      case UserRole.hod:
        return 'Department Overview';
      case UserRole.qaStaff:
        return 'QA Officer · Quality Overview';
      case UserRole.admin:
        return 'Administrator · Quality Overview';
      default:
        return 'Quality Overview';
    }
  }

  String get _subtitle {
    switch (_role) {
      case UserRole.vc:
      case UserRole.dvc:
        return 'Institutional attendance, eligibility, and unstarted sessions.';
      case UserRole.dqa:
        return 'Directorate of Quality Assurance — state of teaching today.';
      case UserRole.dean:
        return 'Faculty roll-up from captured lists and sessions.';
      case UserRole.hod:
        return 'Department roll-up from captured lists and sessions.';
      case UserRole.qaStaff:
        return 'Operational QA view of the same attendance already captured.';
      case UserRole.admin:
        return 'Leadership view of live attendance. Capture stays on Attendance.';
      default:
        return 'Read-only view of attendance already captured in U-Panel.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = RefreshIndicator(
      onRefresh: () => _refresh(force: true),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          _QaatBrandBanner(
            title: _title,
            subtitle: _subtitle,
            roleLabel: _role.label,
            name: AuthRepository.instance.currentFullName,
            refreshing: _refreshing,
            onRefresh: () => unawaited(_refresh(force: true)),
            showOpsHint: _role.hasStaffOperationalAccess,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ProgramFilter(
                  value: _program,
                  onChanged: (p) {
                    setState(() => _program = p);
                    _snap = OversightMetrics.compute(program: _program);
                  },
                ),
                const SizedBox(height: 16),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  _KpiGrid(snap: _snap),
                  const SizedBox(height: 22),
                  const _SectionTitle('Exam eligibility summary'),
                  const SizedBox(height: 10),
                  _EligibilityBars(snap: _snap),
                  if (_snap.ghostSessions.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    const _SectionTitle(
                      'Unstarted sessions (scheduled today)',
                      alert: true,
                    ),
                    const SizedBox(height: 10),
                    _GhostTable(rows: _snap.ghostSessions),
                  ],
                  if (_snap.lecturers.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    const _SectionTitle('Lecturer activity today'),
                    const SizedBox(height: 10),
                    _LecturerTable(rows: _snap.lecturers),
                  ],
                  if (_role == UserRole.dqa ||
                      _role == UserRole.admin ||
                      _role == UserRole.qaStaff) ...[
                    const SizedBox(height: 22),
                    const _SectionTitle('Reports'),
                    const SizedBox(height: 10),
                    _ReportTiles(role: _role),
                  ],
                  if (_snap.atRisk.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    const _SectionTitle('At-risk students (below 75%)'),
                    const SizedBox(height: 10),
                    _AtRiskTable(rows: _snap.atRisk),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );

    return ColoredBox(color: QaatVisuals.page, child: body);
  }
}

class _QaatBrandBanner extends StatelessWidget {
  const _QaatBrandBanner({
    required this.title,
    required this.subtitle,
    required this.roleLabel,
    required this.name,
    required this.refreshing,
    required this.onRefresh,
    required this.showOpsHint,
  });

  final String title;
  final String subtitle;
  final String roleLabel;
  final String? name;
  final bool refreshing;
  final VoidCallback onRefresh;
  final bool showOpsHint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: QaatVisuals.banner,
        border: Border(
          bottom: BorderSide(color: Color(0xFF334155), width: 3),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: QaatVisuals.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
                child: const Text(
                  'KIU-QAAT',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'LEADERSHIP OVERSIGHT',
                style: TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: refreshing ? null : onRefresh,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFE2E8F0),
                ),
                child: refreshing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (name != null && name!.trim().isNotEmpty)
            Text(
              'Welcome, ${name!.trim()}',
              style: const TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 13,
              ),
            ),
          Text(
            title,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(
              color: Color(0xFFCBD5E1),
              fontSize: 14,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _BannerChip(roleLabel),
              const _BannerChip('Read-only · no session capture'),
              if (showOpsHint)
                const _BannerChip('Ops tools remain on Attendance'),
            ],
          ),
        ],
      ),
    );
  }
}

class _BannerChip extends StatelessWidget {
  const _BannerChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: const Color(0xFF475569)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFE2E8F0),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ProgramFilter extends StatelessWidget {
  const _ProgramFilter({required this.value, required this.onChanged});

  final AttendanceProgram? value;
  final ValueChanged<AttendanceProgram?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: QaatVisuals.cardDecoration(),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text(
            'Program',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: QaatVisuals.muted,
            ),
          ),
          ChoiceChip(
            label: const Text('All'),
            selected: value == null,
            onSelected: (_) => onChanged(null),
          ),
          for (final p in AttendanceProgram.values)
            ChoiceChip(
              label: Text(p.label),
              selected: value == p,
              onSelected: (_) => onChanged(p),
            ),
        ],
      ),
    );
  }
}

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.snap});

  final OversightSnapshot snap;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _Kpi('Scheduled sessions', '${snap.scheduledSessions}', accent: true),
      _Kpi('Actual sessions', '${snap.actualSessions}', accent: true),
      _Kpi('Students present', '${snap.studentsPresent}'),
      _Kpi('Avg attendance', '${snap.avgAttendancePct.toStringAsFixed(0)}%'),
      _Kpi(
        'IER',
        '${snap.ier.toStringAsFixed(0)}%',
        tooltip:
            'Institutional Efficiency Ratio = (Actual / Scheduled) × Avg attendance',
      ),
      _Kpi(
        'Unstarted today',
        '${snap.ghostLectureCount}',
        alert: snap.ghostLectureCount > 0,
      ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 720 ? 3 : 2;
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.55,
          children: tiles,
        );
      },
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(
    this.label,
    this.value, {
    this.alert = false,
    this.accent = false,
    this.tooltip,
  });

  final String label;
  final String value;
  final bool alert;
  final bool accent;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: QaatVisuals.card,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: alert ? QaatVisuals.ineligible : QaatVisuals.border,
          width: alert ? 2 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 4,
            height: 48,
            margin: const EdgeInsets.only(right: 12),
            color: alert
                ? QaatVisuals.ineligible
                : (accent ? QaatVisuals.slate : QaatVisuals.accent),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: QaatVisuals.muted,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    height: 1,
                    color: alert ? QaatVisuals.ineligible : QaatVisuals.ink,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (tooltip == null) return card;
    return Tooltip(message: tooltip!, child: card);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.alert = false});

  final String text;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          color: alert ? QaatVisuals.ineligible : QaatVisuals.slate,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: alert ? const Color(0xFFB91C1C) : QaatVisuals.ink,
            ),
          ),
        ),
      ],
    );
  }
}

class _EligibilityBars extends StatelessWidget {
  const _EligibilityBars({required this.snap});

  final OversightSnapshot snap;

  @override
  Widget build(BuildContext context) {
    final rows = [
      ('Eligible', snap.eligible, QaatVisuals.eligible),
      ('Ineligible', snap.ineligible, QaatVisuals.ineligible),
      ('Pending', snap.pending, QaatVisuals.pending),
    ];
    final max = rows.fold<int>(0, (m, r) => r.$2 > m ? r.$2 : m);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: QaatVisuals.cardDecoration(),
      child: Column(
        children: [
          for (final row in rows) ...[
            Row(
              children: [
                SizedBox(
                  width: 88,
                  child: Text(
                    row.$1,
                    style: const TextStyle(fontSize: 13, color: QaatVisuals.ink),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: max == 0 ? 0 : row.$2 / max,
                      minHeight: 14,
                      color: row.$3,
                      backgroundColor: const Color(0xFFF1F5F9),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${row.$2}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: QaatVisuals.ink,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _GhostTable extends StatelessWidget {
  const _GhostTable({required this.rows});

  final List<OversightGhostSession> rows;

  @override
  Widget build(BuildContext context) {
    return _SimpleTable(
      headers: const ['Unit', 'Day', 'On roster'],
      headerTint: const Color(0xFFFEF2F2),
      rows: [
        for (final r in rows) [r.unitName, r.dateLabel, '${r.studentCount}'],
      ],
    );
  }
}

class _LecturerTable extends StatelessWidget {
  const _LecturerTable({required this.rows});

  final List<OversightLecturerRow> rows;

  @override
  Widget build(BuildContext context) {
    return _SimpleTable(
      headers: const ['Lecturer', 'Sessions', 'Turnout'],
      rows: [
        for (final r in rows)
          [
            r.name,
            '${r.sessionCount}',
            '${r.turnoutPct.toStringAsFixed(0)}% (${r.present}/${r.enrolled})',
          ],
      ],
    );
  }
}

class _AtRiskTable extends StatelessWidget {
  const _AtRiskTable({required this.rows});

  final List<OversightStudentRow> rows;

  @override
  Widget build(BuildContext context) {
    return _SimpleTable(
      headers: const ['Student', 'Present / possible', '%'],
      rows: [
        for (final r in rows)
          [r.name, '${r.present} / ${r.possible}', '${r.pct.toStringAsFixed(0)}%'],
      ],
    );
  }
}

class _SimpleTable extends StatelessWidget {
  const _SimpleTable({
    required this.headers,
    required this.rows,
    this.headerTint = const Color(0xFFF8FAFC),
  });

  final List<String> headers;
  final List<List<String>> rows;
  final Color headerTint;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: QaatVisuals.cardDecoration(),
      clipBehavior: Clip.antiAlias,
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(2.2),
          1: FlexColumnWidth(1.2),
          2: FlexColumnWidth(1.4),
        },
        children: [
          TableRow(
            decoration: BoxDecoration(color: headerTint),
            children: [
              for (final h in headers)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Text(
                    h,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: QaatVisuals.ink,
                    ),
                  ),
                ),
            ],
          ),
          for (final row in rows)
            TableRow(
              children: [
                for (final cell in row)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Text(
                      cell,
                      style: const TextStyle(
                        fontSize: 13,
                        color: QaatVisuals.ink,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ReportTiles extends StatelessWidget {
  const _ReportTiles({required this.role});

  final UserRole role;

  @override
  Widget build(BuildContext context) {
    final tiles = <({String label, String desc, VoidCallback onTap})>[
      (
        label: 'Reports',
        desc: 'Print and CSV from captured rolls',
        onTap: () => AppShellScope.of(context).goToSection(AppSection.reports),
      ),
      (
        label: 'Lecturer lessons',
        desc: 'Lesson activity already recorded',
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const QaLessonActivityScreen(),
            ),
          );
        },
      ),
      if (role.hasStaffOperationalAccess)
        (
          label: 'Attendance',
          desc: 'Operational lists and live sessions',
          onTap: () =>
              AppShellScope.of(context).goToSection(AppSection.attendance),
        ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 640 ? 3 : 1;
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 2.4,
          children: [
            for (final t in tiles)
              InkWell(
                onTap: t.onTap,
                borderRadius: BorderRadius.circular(4),
                child: Ink(
                  padding: const EdgeInsets.all(16),
                  decoration: QaatVisuals.cardDecoration(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.label,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: QaatVisuals.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        t.desc,
                        style: const TextStyle(
                          fontSize: 12,
                          color: QaatVisuals.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
