import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'campus_presence_grouping.dart';
import 'campus_presence_policy.dart';
import 'campus_presence_status_widgets.dart';
import 'models/campus_presence_models.dart';

/// Every check-in day for one staff member in the selected period.
class CampusPresenceStaffDetailScreen extends StatelessWidget {
  const CampusPresenceStaffDetailScreen({
    super.key,
    required this.summary,
    required this.periodLabel,
  });

  final StaffPresencePeriodSummary summary;
  final String periodLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = MaterialLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(summary.displayName),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          Text(
            periodLabel,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (summary.staffNumber?.isNotEmpty == true) ...[
            const SizedBox(height: 4),
            Text(
              summary.staffNumber!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
          ],
          if (summary.jobTitle?.isNotEmpty == true) ...[
            const SizedBox(height: 4),
            Text(
              summary.jobTitle!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppTheme.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: 8),
          CampusPresencePeriodStatsChips(summary: summary),
          const SizedBox(height: 8),
          Text(
            '${summary.totalHoursLabel} on campus total',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 20),
          if (summary.dayRows.isEmpty)
            Text(
              'No check-ins recorded.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppTheme.textSecondary,
              ),
            )
          else
            ...[
              for (final row in summary.dayRows) ...[
                _DetailDayCard(row: row, loc: loc),
                const SizedBox(height: 10),
              ],
            ],
        ],
      ),
    );
  }
}

class _DetailDayCard extends StatelessWidget {
  const _DetailDayCard({
    required this.row,
    required this.loc,
  });

  final StaffDayPresenceRow row;
  final MaterialLocalizations loc;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final flags = row.flags();
    final date = CampusPresencePolicy.dateFromLocalDateKey(row.localDateKey);
    final dateLabel =
        date != null ? loc.formatFullDate(date) : row.localDateKey;

    String fmt(CampusPresenceEvent? e) {
      if (e == null) return '—';
      return loc.formatTimeOfDay(TimeOfDay.fromDateTime(e.capturedAt));
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              dateLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (flags.statusLabels.isNotEmpty) ...[
              const SizedBox(height: 8),
              CampusPresenceStatusChips(flags: flags, compact: true),
            ],
            const SizedBox(height: 10),
            CampusPresenceTimeLine(
              icon: Icons.login_rounded,
              label: 'Arrived on campus',
              time: fmt(row.arrival),
              note: flags.arrivalStatusNote,
              active: row.arrival != null,
            ),
            const SizedBox(height: 8),
            CampusPresenceTimeLine(
              icon: Icons.logout_rounded,
              label: 'Left campus',
              time: fmt(row.departure),
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
    );
  }
}
