import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'lesson_insights_models.dart';

class LessonRollCountRow extends StatelessWidget {
  const LessonRollCountRow({
    super.key,
    required this.roll,
    this.compact = false,
  });

  final LessonSessionRollCounts roll;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final chips = [
      _ChipData('Enrolled', roll.enrolled, AppTheme.primary),
      _ChipData('Present', roll.present, AppTheme.success),
      _ChipData('Absent', roll.absent, AppTheme.error),
      _ChipData('Pending', roll.pending, AppTheme.warning),
    ];
    if (compact) {
      return Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final c in chips)
            Text(
              '${c.label} ${c.value}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: c.color,
                    fontWeight: FontWeight.w700,
                  ),
            ),
        ],
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [for (final c in chips) _countChip(context, c)],
    );
  }

  Widget _countChip(BuildContext context, _ChipData c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '${c.label} ${c.value}',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: c.color,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _ChipData {
  const _ChipData(this.label, this.value, this.color);
  final String label;
  final int value;
  final Color color;
}

class LessonSessionInsightCard extends StatelessWidget {
  const LessonSessionInsightCard({
    super.key,
    required this.insight,
    this.onTap,
  });

  final LessonSessionInsight insight;
  final VoidCallback? onTap;

  String _timeRange() {
    final s = insight.session.startTime.toLocal();
    final e = insight.session.endTime.toLocal();
    String t(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return '${t(s)} – ${t(e)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = insight.list;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          insight.courseLabel,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          list.displaySubtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.softGrey),
                    ),
                    child: Text(
                      insight.session.sessionCode,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AppTheme.primary,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _meta(Icons.meeting_room_outlined, list.room),
                  _meta(Icons.schedule_rounded, _timeRange()),
                  _meta(Icons.school_outlined, insight.yearSemLabel),
                ],
              ),
              if (list.coursesSafe.length > 1) ...[
                const SizedBox(height: 8),
                Text(
                  'Courses: ${list.coursesSafe.join(' · ')}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                    height: 1.35,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              LessonRollCountRow(roll: insight.roll),
            ],
          ),
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: AppTheme.textSecondary),
        const SizedBox(width: 4),
        Text(
          text,
          style: const TextStyle(
            fontSize: 12,
            color: AppTheme.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
