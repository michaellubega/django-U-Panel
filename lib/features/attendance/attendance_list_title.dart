import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'models/attendance_models.dart';

/// Course unit name with lecturer and room on the line below (list browse, profile, etc.).
class AttendanceListTitleColumn extends StatelessWidget {
  const AttendanceListTitleColumn({
    super.key,
    required this.list,
    this.titleStyle,
    this.subtitleStyle,
    this.titleMaxLines = 2,
    this.subtitleMaxLines = 2,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  final AttendanceList list;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final int titleMaxLines;
  final int subtitleMaxLines;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = list.displaySubtitle;
    return Column(
      crossAxisAlignment: crossAxisAlignment,
      children: [
        Text(
          list.displayTitle,
          maxLines: titleMaxLines,
          overflow: TextOverflow.ellipsis,
          style: titleStyle ??
              theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.2,
                color: AppTheme.textPrimary,
              ),
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: subtitleMaxLines,
            overflow: TextOverflow.ellipsis,
            style: subtitleStyle ??
                theme.textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                  height: 1.28,
                ),
          ),
        ],
      ],
    );
  }
}

/// Same layout when only title strings are available (e.g. profile roll rows).
class AttendanceListTitleStringsColumn extends StatelessWidget {
  const AttendanceListTitleStringsColumn({
    super.key,
    required this.title,
    this.subtitle = '',
    this.titleStyle,
    this.subtitleStyle,
    this.titleMaxLines = 2,
    this.subtitleMaxLines = 2,
  });

  final String title;
  final String subtitle;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final int titleMaxLines;
  final int subtitleMaxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = subtitle.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: titleMaxLines,
          overflow: TextOverflow.ellipsis,
          style: titleStyle ??
              theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            sub,
            maxLines: subtitleMaxLines,
            overflow: TextOverflow.ellipsis,
            style: subtitleStyle ??
                theme.textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                  height: 1.35,
                ),
          ),
        ],
      ],
    );
  }
}
