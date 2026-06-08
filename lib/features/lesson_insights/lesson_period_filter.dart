import 'package:flutter/material.dart';

enum LessonPeriodFilter {
  day,
  week,
  month,
}

extension LessonPeriodFilterX on LessonPeriodFilter {
  String get label => switch (this) {
        LessonPeriodFilter.day => 'Day',
        LessonPeriodFilter.week => 'Week',
        LessonPeriodFilter.month => 'Month',
      };

  String describeRange(DateTime anchor) {
    final (start, end) = dateRange(anchor);
    String fmt(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    if (this == LessonPeriodFilter.day) return fmt(start);
    return '${fmt(start)} – ${fmt(end)}';
  }

  (DateTime start, DateTime end) dateRange(DateTime anchor) {
    final local = DateTime(anchor.year, anchor.month, anchor.day);
    switch (this) {
      case LessonPeriodFilter.day:
        return (local, local);
      case LessonPeriodFilter.week:
        final start = local.subtract(Duration(days: local.weekday - 1));
        final end = start.add(const Duration(days: 6));
        return (start, end);
      case LessonPeriodFilter.month:
        final start = DateTime(local.year, local.month, 1);
        final end = DateTime(local.year, local.month + 1, 0);
        return (start, end);
    }
  }

  bool containsSessionStart(DateTime sessionStart) {
    final local = DateTime(
      sessionStart.year,
      sessionStart.month,
      sessionStart.day,
    );
    final (start, end) = dateRange(DateTime.now());
    return !local.isBefore(start) && !local.isAfter(end);
  }

  bool containsSessionStartOn(DateTime sessionStart, DateTime anchor) {
    final local = DateTime(
      sessionStart.year,
      sessionStart.month,
      sessionStart.day,
    );
    final (start, end) = dateRange(anchor);
    return !local.isBefore(start) && !local.isAfter(end);
  }
}

/// Day | Week | Month filter control used on lesson insight screens.
class LessonPeriodFilterBar extends StatelessWidget {
  const LessonPeriodFilterBar({
    super.key,
    required this.filter,
    required this.anchorDate,
    required this.onFilterChanged,
    required this.onAnchorChanged,
  });

  final LessonPeriodFilter filter;
  final DateTime anchorDate;
  final ValueChanged<LessonPeriodFilter> onFilterChanged;
  final ValueChanged<DateTime> onAnchorChanged;

  Future<void> _pickDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: anchorDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) onAnchorChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<LessonPeriodFilter>(
          segments: [
            for (final f in LessonPeriodFilter.values)
              ButtonSegment(value: f, label: Text(f.label)),
          ],
          selected: {filter},
          onSelectionChanged: (s) => onFilterChanged(s.first),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => _pickDate(context),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(Icons.calendar_today_rounded,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    filter.describeRange(anchorDate),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Icon(Icons.edit_calendar_rounded, size: 20),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
