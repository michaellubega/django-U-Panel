import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Persistent error or warning banner with an X control to dismiss.
class DismissibleErrorBanner extends StatelessWidget {
  const DismissibleErrorBanner({
    super.key,
    required this.message,
    required this.onDismiss,
    this.leadingIcon = Icons.error_outline,
    this.dismissEnabled = true,
  });

  final String message;
  final VoidCallback onDismiss;
  final IconData leadingIcon;
  final bool dismissEnabled;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.error.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.error.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(leadingIcon, color: AppTheme.error, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              onPressed: dismissEnabled ? onDismiss : null,
              icon: const Icon(Icons.close_rounded, size: 22),
              color: AppTheme.textSecondary,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ],
        ),
      ),
    );
  }
}
