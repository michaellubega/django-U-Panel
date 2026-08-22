import 'package:flutter/material.dart';

import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';
import 'campus_presence_grouping.dart';
import 'campus_presence_policy.dart';
import 'campus_presence_status_widgets.dart';
import 'campus_presence_staff_detail_screen.dart';
import 'data/campus_presence_repository.dart';
import 'models/campus_presence_models.dart';

/// Campus presence log: day (grouped rows), week/month (totals per staff).
class CampusPresenceLogScreen extends StatefulWidget {
  const CampusPresenceLogScreen({super.key});

  @override
  State<CampusPresenceLogScreen> createState() =>
      _CampusPresenceLogScreenState();
}

class _CampusPresenceLogScreenState extends State<CampusPresenceLogScreen> {
  CampusPresenceLogPeriod _period = CampusPresenceLogPeriod.day;
  DateTime _anchor = DateTime.now();
  bool _loading = true;
  List<CampusPresenceEvent> _events = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final range = localDateRangeForPeriod(_period, _anchor);
    final events =
        await CampusPresenceRepository.instance.fetchEventsInLocalDateRange(
      rangeStart: range.start,
      rangeEnd: range.end,
    );
    if (!mounted) return;
    setState(() {
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

  void _openStaffDetail(StaffPresencePeriodSummary summary) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CampusPresenceStaffDetailScreen(
          summary: summary,
          periodLabel: _periodTitle(MaterialLocalizations.of(context)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = MaterialLocalizations.of(context);
    final title = _periodTitle(loc);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Campus presence log'),
        actions: [
          RefreshIconButton(onRefresh: _load),
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
              title,
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
                  : _period == CampusPresenceLogPeriod.day
                      ? _DayList(
                          anchor: _anchor,
                          events: _events,
                          onStaffTap: _openStaffDetail,
                        )
                      : _PeriodSummaryList(
                          period: _period,
                          events: _events,
                          onStaffTap: _openStaffDetail,
                        ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayList extends StatelessWidget {
  const _DayList({
    required this.anchor,
    required this.events,
    required this.onStaffTap,
  });

  final DateTime anchor;
  final List<CampusPresenceEvent> events;
  final void Function(StaffPresencePeriodSummary summary) onStaffTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = localDateKeyFor(anchor);
    final rows = dayRowsForSingleLocalDate(events, key);

    if (rows.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'No campus check-ins for this day.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final row = rows[index];
        return _StaffDayCard(
          row: row,
          onTap: () => onStaffTap(
            StaffPresencePeriodSummary(
              adminUid: row.adminUid,
              displayName: row.displayName,
              staffNumber: row.staffNumber,
              checkInCount: row.hasCheckIn ? 1 : 0,
              dayRows: [row],
            ),
          ),
        );
      },
    );
  }
}

class _PeriodSummaryList extends StatelessWidget {
  const _PeriodSummaryList({
    required this.period,
    required this.events,
    required this.onStaffTap,
  });

  final CampusPresenceLogPeriod period;
  final List<CampusPresenceEvent> events;
  final void Function(StaffPresencePeriodSummary summary) onStaffTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summaries = summarizeCheckInsByStaff(events);
    final showPeriodStats = period == CampusPresenceLogPeriod.month ||
        period == CampusPresenceLogPeriod.week;

    if (summaries.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'No check-ins in this period.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: summaries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final s = summaries[index];
        return Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onStaffTap(s),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          s.displayName,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${s.checkInCount}×',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: AppTheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: AppTheme.textSecondary.withValues(alpha: 0.7),
                      ),
                    ],
                  ),
                  if (s.staffNumber?.isNotEmpty == true) ...[
                    const SizedBox(height: 2),
                    Text(
                      s.staffNumber!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                  if (s.jobTitle?.isNotEmpty == true) ...[
                    const SizedBox(height: 2),
                    Text(
                      s.jobTitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  if (showPeriodStats) ...[
                    CampusPresencePeriodStatsChips(summary: s),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    '${s.totalHoursLabel} on campus total',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppTheme.textSecondary,
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
}

class _StaffDayCard extends StatelessWidget {
  const _StaffDayCard({
    required this.row,
    this.onTap,
  });

  final StaffDayPresenceRow row;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = MaterialLocalizations.of(context);
    final flags = row.flags();

    String? timeLine(CampusPresenceEvent? e) {
      if (e == null) return null;
      return loc.formatTimeOfDay(TimeOfDay.fromDateTime(e.capturedAt));
    }

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      row.displayName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (onTap != null)
                    Icon(
                      Icons.chevron_right_rounded,
                      color: AppTheme.textSecondary.withValues(alpha: 0.7),
                    ),
                ],
              ),
              if (row.staffNumber?.isNotEmpty == true) ...[
                const SizedBox(height: 2),
                Text(
                  row.staffNumber!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
              if (row.jobTitle?.isNotEmpty == true) ...[
                const SizedBox(height: 2),
                Text(
                  row.jobTitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
              if (flags.statusLabels.isNotEmpty) ...[
                const SizedBox(height: 8),
                CampusPresenceStatusChips(flags: flags, compact: true),
              ],
              const SizedBox(height: 10),
              CampusPresenceTimeLine(
                icon: Icons.login_rounded,
                label: 'Arrived',
                time: timeLine(row.arrival),
                note: flags.arrivalStatusNote,
                active: row.arrival != null,
              ),
              const SizedBox(height: 6),
              CampusPresenceTimeLine(
                icon: Icons.logout_rounded,
                label: 'Left',
                time: timeLine(row.departure),
                note: flags.departureStatusNote,
                active: row.departure != null || flags.failedCheckout,
              ),
              if (row.arrival != null) ...[
                const SizedBox(height: 10),
                CampusPresenceHoursLine(flags: flags),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
