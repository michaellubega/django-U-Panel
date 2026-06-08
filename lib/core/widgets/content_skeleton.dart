import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Placeholder rows while content loads — keeps layout stable without a spinner.
class ContentSkeleton extends StatelessWidget {
  const ContentSkeleton({
    super.key,
    this.rows = 4,
    this.rowHeight = 72,
    this.padding = const EdgeInsets.all(16),
  });

  final int rows;
  final double rowHeight;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      padding: padding,
      itemCount: rows,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          height: rowHeight,
          decoration: BoxDecoration(
            color: AppTheme.softGrey.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}
