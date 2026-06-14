import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';
import 'admin_presence_roll_export.dart';
import '../campus_presence/admin_campus_absent_list_screen.dart';
import '../campus_presence/campus_presence_grouping.dart';
import '../campus_presence/campus_presence_policy.dart';
import '../campus_presence/campus_presence_staff_detail_screen.dart';
import '../campus_presence/data/campus_presence_repository.dart';
import '../campus_presence/models/campus_presence_models.dart';

/// KIU admin campus presence as an attendance-style roll (admins × dates).
class ReportsAdminPresenceRollScreen extends StatefulWidget {
  const ReportsAdminPresenceRollScreen({super.key});

  @override
  State<ReportsAdminPresenceRollScreen> createState() =>
      _ReportsAdminPresenceRollScreenState();
}

class _ReportsAdminPresenceRollScreenState
    extends State<ReportsAdminPresenceRollScreen> {
  CampusPresenceLogPeriod _period = CampusPresenceLogPeriod.week;
  DateTime _anchor = DateTime.now();
  bool _loading = true;
  bool _exportBusy = false;
  List<AdminCampusRosterEntry> _roster = const [];
  List<CampusPresenceEvent> _events = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final range = localDateRangeForPeriod(_period, _anchor);
    final repo = CampusPresenceRepository.instance;
    final roster = await repo.fetchKiuAdminRoster();
    final events = await repo.fetchEventsInLocalDateRange(
      rangeStart: range.start,
      rangeEnd: range.end,
    );
    if (!mounted) return;
    setState(() {
      _roster = roster;
      _events = events;
      _loading = false;
    });
  }

  Future<void> _pickAnchorDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _anchor,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() => _anchor = picked);
    await _load();
  }

  Future<void> _exportPdf() async {
    setState(() => _exportBusy = true);
    try {
      final path = await exportAdminPresenceRollPdf(
        period: _period,
        anchor: _anchor,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            path != null
                ? 'PDF saved to $path'
                : 'PDF downloaded to your device',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save PDF: $e')),
      );
    } finally {
      if (mounted) setState(() => _exportBusy = false);
    }
  }

  List<String> _dateKeysInRange() {
    final range = localDateRangeForPeriod(_period, _anchor);
    final keys = <String>[];
    var day = range.start;
    while (!day.isAfter(range.end)) {
      keys.add(localDateKeyFor(day));
      day = day.add(const Duration(days: 1));
    }
    return keys.reversed.toList();
  }

  static bool _isWeekday(DateTime day) =>
      day.weekday != DateTime.saturday && day.weekday != DateTime.sunday;

  _AdminPeriodStats _periodStatsFor(
    String adminUid,
    List<String> dateKeys,
    Map<String, Map<String, StaffDayPresenceRow>> cellMap,
  ) {
    final byDate = cellMap[adminUid] ?? {};
    var overwork = Duration.zero;
    var late = Duration.zero;
    var daysPresent = 0;
    var weekdaysAbsent = 0;

    for (final key in dateKeys) {
      final date = CampusPresencePolicy.dateFromLocalDateKey(key);
      if (date == null) continue;
      final row = byDate[key];
      if (row != null && row.hasCheckIn) {
        daysPresent++;
        final arrival = row.arrival?.capturedAt;
        if (arrival != null) {
          final lateness = CampusPresencePolicy.latenessAfterThreshold(arrival);
          if (lateness != null) late += lateness;
        }
        final departure = row.departure?.capturedAt;
        if (departure != null) {
          final over = CampusPresencePolicy.overworkAfterThreshold(departure);
          if (over != null) overwork += over;
        }
      } else if (_isWeekday(date)) {
        weekdaysAbsent++;
      }
    }

    return _AdminPeriodStats(
      totalOverwork: overwork,
      totalLate: late,
      daysPresent: daysPresent,
      weekdaysAbsent: weekdaysAbsent,
    );
  }

  String? _latestPresenceKey(
    String adminUid,
    Map<String, Map<String, StaffDayPresenceRow>> cellMap,
  ) {
    final byDate = cellMap[adminUid];
    if (byDate == null || byDate.isEmpty) return null;
    final keys = byDate.entries
        .where((e) => e.value.hasCheckIn)
        .map((e) => e.key)
        .toList()
      ..sort((a, b) => b.compareTo(a));
    return keys.isEmpty ? null : keys.first;
  }

  List<AdminCampusRosterEntry> _sortedAdmins(
    List<AdminCampusRosterEntry> roster,
    Map<String, Map<String, StaffDayPresenceRow>> cellMap,
  ) {
    final copy = [...roster];
    copy.sort((a, b) {
      final latestA = _latestPresenceKey(a.uid, cellMap);
      final latestB = _latestPresenceKey(b.uid, cellMap);
      if (latestA != null && latestB != null) {
        final byDate = latestB.compareTo(latestA);
        if (byDate != 0) return byDate;
      } else if (latestA != null) {
        return -1;
      } else if (latestB != null) {
        return 1;
      }
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return copy;
  }

  Map<String, Map<String, StaffDayPresenceRow>> _rowsByAdminAndDate() {
    final grouped = groupEventsIntoDayRows(_events);
    final map = <String, Map<String, StaffDayPresenceRow>>{};
    for (final row in grouped) {
      (map[row.adminUid] ??= {})[row.localDateKey] = row;
    }
    return map;
  }

  void _openAdminDetail(AdminCampusRosterEntry admin) {
    final byDate = _rowsByAdminAndDate()[admin.uid] ?? {};
    final dayRows = byDate.values.toList()
      ..sort((a, b) => b.localDateKey.compareTo(a.localDateKey));
    final summary = StaffPresencePeriodSummary(
      adminUid: admin.uid,
      displayName: admin.displayName,
      staffNumber: admin.staffNumber,
      jobTitle: admin.jobTitle,
      checkInCount: dayRows.where((r) => r.hasCheckIn).length,
      dayRows: dayRows,
    );
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CampusPresenceStaffDetailScreen(
          summary: summary,
          periodLabel: _periodTitle(MaterialLocalizations.of(context)),
        ),
      ),
    );
  }

  String _periodTitle(MaterialLocalizations loc) {
    final range = localDateRangeForPeriod(_period, _anchor);
    switch (_period) {
      case CampusPresenceLogPeriod.day:
        return loc.formatFullDate(_anchor);
      case CampusPresenceLogPeriod.week:
        return '${loc.formatShortDate(range.start)} – ${loc.formatShortDate(range.end)}';
      case CampusPresenceLogPeriod.month:
        return '${_monthName(_anchor.month)} ${_anchor.year}';
    }
  }

  static String _monthName(int month) {
    const names = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return names[month - 1];
  }

  String _fmtDateKey(String key) {
    final d = CampusPresencePolicy.dateFromLocalDateKey(key);
    if (d == null) return key;
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = MaterialLocalizations.of(context);
    final dateKeys = _dateKeysInRange();
    final cellMap = _rowsByAdminAndDate();
    final admins = _sortedAdmins(_roster, cellMap);

    return Scaffold(
      appBar: AppBar(
        title: const Text('KIU admin presence'),
        actions: [
          RefreshIconButton(onRefresh: _load),
          IconButton(
            tooltip: 'Export PDF',
            onPressed: _exportBusy ? null : _exportPdf,
            icon: _exportBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf_rounded),
          ),
          IconButton(
            tooltip: 'Absent today',
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const AdminCampusAbsentListScreen(),
                ),
              );
            },
            icon: const Icon(Icons.person_off_rounded),
          ),
          IconButton(
            tooltip: 'Pick date',
            onPressed: _pickAnchorDate,
            icon: const Icon(Icons.calendar_today_rounded),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SegmentedButton<CampusPresenceLogPeriod>(
              segments: [
                for (final p in CampusPresenceLogPeriod.values)
                  ButtonSegment(value: p, label: Text(p.label)),
              ],
              selected: {_period},
              onSelectionChanged: (s) {
                setState(() => _period = s.first);
                _load();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              _periodTitle(loc),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _loading
                  ? ListView(
                      physics: kRefreshScrollPhysics,
                      children: const [
                        SizedBox(height: 120),
                        Center(child: CircularProgressIndicator()),
                      ],
                    )
                  : admins.isEmpty
                      ? ListView(
                          physics: kRefreshScrollPhysics,
                          padding: const EdgeInsets.all(24),
                          children: [
                            Text(
                              'No KIU administrators on the roster yet.',
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        )
                      : ListView(
                          physics: kRefreshScrollPhysics,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          children: [
                            _AdminPresenceRollSummary(
                              adminCount: admins.length,
                              dateCount: dateKeys.length,
                              checkInDays: cellMap.values
                                  .expand((m) => m.values)
                                  .where((r) => r.hasCheckIn)
                                  .length,
                            ),
                            const SizedBox(height: 16),
                            Card(
                              clipBehavior: Clip.antiAlias,
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: DataTable(
                                  headingRowHeight: 44,
                                  dataRowMinHeight: 72,
                                  dataRowMaxHeight: 140,
                                  columnSpacing: 12,
                                  columns: [
                                    const DataColumn(
                                      label: Text(
                                        'Administrator',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const DataColumn(
                                      label: Text(
                                        'Period totals',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    for (final key in dateKeys)
                                      DataColumn(
                                        label: Text(
                                          _fmtDateKey(key),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                  ],
                                  rows: [
                                    for (final admin in admins)
                                      DataRow(
                                        onSelectChanged: (_) =>
                                            _openAdminDetail(admin),
                                        cells: [
                                          DataCell(
                                            SizedBox(
                                              width: 160,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Text(
                                                    admin.displayName,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                  if (admin.staffNumber
                                                          ?.isNotEmpty ==
                                                      true)
                                                    Text(
                                                      admin.staffNumber!,
                                                      style: const TextStyle(
                                                        color: AppTheme
                                                            .textSecondary,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  if (admin.jobTitle
                                                          ?.isNotEmpty ==
                                                      true)
                                                    Text(
                                                      admin.jobTitle!,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        color: AppTheme
                                                            .textSecondary,
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            SizedBox(
                                              width: 132,
                                              child: _AdminPeriodTotalsCell(
                                                stats: _periodStatsFor(
                                                  admin.uid,
                                                  dateKeys,
                                                  cellMap,
                                                ),
                                              ),
                                            ),
                                          ),
                                          for (final key in dateKeys)
                                            DataCell(
                                              SizedBox(
                                                width: 118,
                                                child: _AdminPresenceRollCell(
                                                  row: cellMap[admin.uid]?[key],
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminPeriodStats {
  const _AdminPeriodStats({
    required this.totalOverwork,
    required this.totalLate,
    required this.daysPresent,
    required this.weekdaysAbsent,
  });

  final Duration totalOverwork;
  final Duration totalLate;
  final int daysPresent;
  final int weekdaysAbsent;
}

class _AdminPeriodTotalsCell extends StatelessWidget {
  const _AdminPeriodTotalsCell({required this.stats});

  final _AdminPeriodStats stats;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _line(
          'Overwork',
          CampusPresencePolicy.formatDuration(stats.totalOverwork),
          AppTheme.accent,
        ),
        _line(
          'Late',
          CampusPresencePolicy.formatDuration(stats.totalLate),
          AppTheme.warning,
        ),
        _line('Present', '${stats.daysPresent} days', AppTheme.success),
        _line('Absent', '${stats.weekdaysAbsent} weekdays', AppTheme.error),
      ],
    );
  }

  Widget _line(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary),
          children: [
            TextSpan(text: '$label: '),
            TextSpan(
              text: value,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: color,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminPresenceRollSummary extends StatelessWidget {
  const _AdminPresenceRollSummary({
    required this.adminCount,
    required this.dateCount,
    required this.checkInDays,
  });

  final int adminCount;
  final int dateCount;
  final int checkInDays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.background,
            AppTheme.accentLight.withValues(alpha: 0.4),
          ],
        ),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.12)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _chip(theme, Icons.badge_rounded, '$adminCount admins'),
          _chip(theme, Icons.date_range_rounded, '$dateCount days'),
          _chip(
            theme,
            Icons.login_rounded,
            '$checkInDays check-ins',
            color: AppTheme.success,
          ),
        ],
      ),
    );
  }

  Widget _chip(
    ThemeData theme,
    IconData icon,
    String label, {
    Color? color,
  }) {
    final c = color ?? AppTheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.softGrey.withValues(alpha: 0.85)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: c),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminPresenceRollCell extends StatelessWidget {
  const _AdminPresenceRollCell({this.row});

  final StaffDayPresenceRow? row;

  @override
  Widget build(BuildContext context) {
    if (row == null || !row!.hasCheckIn) {
      return Text(
        'Absent',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppTheme.error,
              fontWeight: FontWeight.w600,
            ),
      );
    }

    final loc = MaterialLocalizations.of(context);
    final flags = row!.flags();
    String fmt(CampusPresenceEvent? e) {
      if (e == null) return '—';
      return loc.formatTimeOfDay(TimeOfDay.fromDateTime(e.capturedAt));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'In ${fmt(row!.arrival)}',
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppTheme.primary,
          ),
        ),
        Text(
          'Out ${fmt(row!.departure)}',
          style: const TextStyle(
            fontSize: 11,
            color: AppTheme.textSecondary,
          ),
        ),
        if (flags.lateArrival)
          Text(
            flags.arrivalStatusNote ?? 'Late',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppTheme.warning,
            ),
          ),
        if (flags.overwork)
          Text(
            flags.departureStatusNotes
                    .where((n) => n.startsWith('Overwork'))
                    .firstOrNull ??
                'Overwork',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppTheme.accent,
            ),
          ),
        if (flags.earlyDeparture && !flags.overwork)
          Text(
            flags.departureStatusNotes
                    .where((n) => n.startsWith('Left early'))
                    .firstOrNull ??
                'Left early',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary,
            ),
          ),
        if (row!.arrival != null)
          Text(
            flags.hoursLabel,
            style: const TextStyle(
              fontSize: 10,
              color: AppTheme.textSecondary,
            ),
          ),
      ],
    );
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    if (!it.moveNext()) return null;
    return it.current;
  }
}
