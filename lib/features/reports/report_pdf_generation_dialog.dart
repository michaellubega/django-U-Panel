import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Shows a blocking dialog while [task] runs, then dismisses it automatically.
Future<T?> runWithReportPdfGenerationDialog<T>(
  BuildContext context, {
  required Future<T?> Function() task,
  String message = 'Generating PDF…',
  String subtitle = 'Please wait while your report is prepared.',
}) async {
  if (!context.mounted) return null;

  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: _ReportPdfGenerationContent(
          message: message,
          subtitle: subtitle,
        ),
      ),
    ),
  );

  await Future<void>.delayed(Duration.zero);

  try {
    return await task();
  } finally {
    if (navigator.mounted) {
      navigator.pop();
    }
  }
}

class _ReportPdfGenerationContent extends StatelessWidget {
  const _ReportPdfGenerationContent({
    required this.message,
    required this.subtitle,
  });

  final String message;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 280,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.picture_as_pdf_rounded,
            size: 40,
            color: AppTheme.primary,
          ),
          const SizedBox(height: 16),
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: AppTheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppTheme.textSecondary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
