import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'campus_presence_grouping.dart';
import 'campus_presence_policy.dart';

class CampusPresenceStatusChips extends StatelessWidget {
  const CampusPresenceStatusChips({
    super.key,
    required this.flags,
    this.compact = false,
  });

  final CampusDayPresenceFlags flags;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (flags.statusLabels.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final label in flags.statusLabels)
          CampusPresenceTagChip(label: label, compact: compact),
      ],
    );
  }
}

class CampusPresenceHoursLine extends StatelessWidget {
  const CampusPresenceHoursLine({
    super.key,
    required this.flags,
  });

  final CampusDayPresenceFlags flags;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suffix = flags.failedCheckout
        ? ' (until midnight, no check-out)'
        : (flags.statusLabels.contains('On campus') ? ' (so far)' : '');

    return Row(
      children: [
        Icon(
          Icons.schedule_rounded,
          size: 18,
          color: AppTheme.textSecondary,
        ),
        const SizedBox(width: 8),
        Text(
          'On campus: ',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppTheme.textSecondary,
          ),
        ),
        Text(
          '${flags.hoursLabel}$suffix',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class CampusPresenceTagChip extends StatelessWidget {
  const CampusPresenceTagChip({
    super.key,
    required this.label,
    this.compact = false,
  });

  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = campusPresenceTagColors(label);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

(Color, Color) campusPresenceTagColors(String label) {
  if (label.startsWith('Late')) {
    return (AppTheme.warning.withValues(alpha: 0.18), AppTheme.warning);
  }
  if (label.startsWith('Left early') || label.startsWith('Early leave')) {
    return (AppTheme.warning.withValues(alpha: 0.12), AppTheme.warning);
  }
  if (label.startsWith('Late arrivals')) {
    return (AppTheme.warning.withValues(alpha: 0.18), AppTheme.warning);
  }
  if (label.startsWith('Overwork') || label.startsWith('Total overwork')) {
    return (AppTheme.primary.withValues(alpha: 0.12), AppTheme.primary);
  }
  if (label.startsWith('Failed to check out')) {
    return (AppTheme.error.withValues(alpha: 0.14), AppTheme.error);
  }
  if (label.startsWith('On campus') || label.startsWith('Campus visits')) {
    return (AppTheme.success.withValues(alpha: 0.14), AppTheme.success);
  }
  return (AppTheme.softGrey.withValues(alpha: 0.35), AppTheme.textSecondary);
}

/// Week / month totals beside a staff member's name.
class CampusPresencePeriodStatsChips extends StatelessWidget {
  const CampusPresencePeriodStatsChips({
    super.key,
    required this.summary,
    this.compact = true,
  });

  final StaffPresencePeriodSummary summary;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        CampusPresenceTagChip(
          label: summary.campusVisitLabel,
          compact: compact,
        ),
        CampusPresenceTagChip(
          label: summary.lateArrivalCountLabel,
          compact: compact,
        ),
        CampusPresenceTagChip(
          label: summary.earlyLeaveCountLabel,
          compact: compact,
        ),
        CampusPresenceTagChip(
          label: summary.totalOverworkSummaryLabel,
          compact: compact,
        ),
      ],
    );
  }
}

/// Arrival / departure line with optional late / early / overwork hint.
class CampusPresenceTimeLine extends StatelessWidget {
  const CampusPresenceTimeLine({
    super.key,
    required this.icon,
    required this.label,
    required this.time,
    this.note,
    required this.active,
  });

  final IconData icon;
  final String label;
  final String? time;
  final String? note;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: active ? AppTheme.primary : AppTheme.softGrey),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
              if (note != null && active)
                Text(
                  note!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _noteColor(note!),
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
        Text(
          time ?? '—',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            color: active ? null : AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }

  Color _noteColor(String note) {
    if (note.contains('Late') ||
        note.contains('early') ||
        note.contains('Failed')) {
      return AppTheme.warning;
    }
    if (note.contains('Overwork')) return AppTheme.primary;
    return AppTheme.textSecondary;
  }
}
