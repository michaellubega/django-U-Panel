import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/attendance_list_title.dart';
import '../attendance/models/attendance_models.dart';
import 'attendance_list_roll.dart';
import 'report_download.dart';
import 'report_print.dart';
import 'reports_csv_data.dart';

/// Consolidated roll for one class list with print and CSV export.
class AttendanceListRollReportScreen extends StatefulWidget {
  const AttendanceListRollReportScreen({super.key, required this.list});

  final AttendanceList list;

  @override
  State<AttendanceListRollReportScreen> createState() =>
      _AttendanceListRollReportScreenState();
}

class _AttendanceListRollReportScreenState
    extends State<AttendanceListRollReportScreen> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await AttendanceRepository.instance.loadAll(
        force: true,
        scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  Future<void> _exportCsv(AttendanceListRollData roll) async {
    const bom = '\uFEFF';
    final csv = '$bom${buildSingleListRollCsv(roll.list)}';
    await Clipboard.setData(ClipboardData(text: csv));
    final safeTitle = roll.list.displayTitle
        .replaceAll(RegExp(r'[^\w.\- ]'), '_')
        .replaceAll(' ', '_');
    final date = DateTime.now().toIso8601String().split('T').first;
    await maybeDownloadReportCsv('u_panel_roll_${safeTitle}_$date.csv', csv);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Roll CSV copied. On web, download should start.')),
    );
  }

  Future<void> _printRoll(AttendanceListRollData roll) async {
    final plain = buildAttendanceListRollPlainText(roll);
    await printAttendanceRollText(
      title: attendanceListRollPrintTitle(roll),
      plainText: plain,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          Theme.of(context).platform == TargetPlatform.iOS ||
                  Theme.of(context).platform == TargetPlatform.android
              ? 'Roll copied — paste into Notes or a spreadsheet to print.'
              : 'Print dialog opened (web) or roll copied to clipboard.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final roll = buildAttendanceListRoll(widget.list);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: AttendanceListTitleColumn(
          list: widget.list,
          titleStyle: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
          subtitleStyle: theme.textTheme.bodySmall?.copyWith(
            color: Colors.white.withValues(alpha: 0.85),
          ),
          titleMaxLines: 1,
          subtitleMaxLines: 1,
        ),
        actions: [
          IconButton(
            icon: _refreshing
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: _refreshing ? null : _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.table_chart_outlined),
            tooltip: 'Export CSV',
            onPressed: () => _exportCsv(roll),
          ),
          IconButton(
            icon: const Icon(Icons.print_rounded),
            tooltip: 'Print this list',
            onPressed: () => _printRoll(roll),
          ),
        ],
      ),
      body: roll.students.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No students on this list yet.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _RollSummaryHeader(roll: roll),
                const SizedBox(height: 16),
                Card(
                  clipBehavior: Clip.antiAlias,
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
                          label: Text('Student',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                        ),
                        for (final s in roll.sessions)
                          DataColumn(
                            label: Text(
                              _fmtDate(s.startTime),
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                      ],
                      rows: roll.students.map((row) {
                        return DataRow(
                          cells: [
                            DataCell(Text(
                              '${row.attendancePercent}%',
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
                                      row.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      row.registrationNumber,
                                      style: const TextStyle(
                                        color: AppTheme.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            for (final s in roll.sessions)
                              DataCell(
                                SizedBox(
                                  width: 110,
                                  child: Builder(
                                    builder: (context) {
                                      final label = row.sessionLabels[s.id];
                                      final text = (label ?? '—').toLowerCase();
                                      final color = label == null
                                          ? AppTheme.textSecondary
                                          : label == 'Present'
                                              ? AppTheme.primary
                                              : AppTheme.error;
                                      return Text(
                                        text,
                                        style: TextStyle(
                                          color: color,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _RollSummaryHeader extends StatelessWidget {
  const _RollSummaryHeader({required this.roll});

  final AttendanceListRollData roll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.background,
            AppTheme.accentLight.withValues(alpha: 0.45),
          ],
        ),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AttendanceListTitleColumn(
            list: roll.list,
            titleStyle: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatChip(
                icon: Icons.groups_rounded,
                label: '${roll.rosterCount} students',
              ),
              _StatChip(
                icon: Icons.event_note_rounded,
                label: '${roll.sessions.length} sessions',
              ),
              _StatChip(
                icon: Icons.check_circle_outline_rounded,
                label: '${roll.presentRollRows} present',
                color: AppTheme.primary,
              ),
              _StatChip(
                icon: Icons.cancel_outlined,
                label: '${roll.absentRollRows} absent',
                color: AppTheme.error,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.softGrey.withValues(alpha: 0.85)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
          ),
        ],
      ),
    );
  }
}
