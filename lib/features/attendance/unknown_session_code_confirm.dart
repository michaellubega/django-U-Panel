import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'data/pending_retention.dart';

/// Student answer when a session code is not found on the server yet.
enum UnknownSessionCodeConfirmChoice {
  /// Code matches what the lecturer showed; queue for up to 7 days.
  codeIsCorrect,

  /// Return to attendance form to type a different code.
  codeIsWrong,
}

/// Asks the student to confirm an unknown code before it is queued locally.
Future<UnknownSessionCodeConfirmChoice?> showUnknownSessionCodeConfirmDialog({
  required BuildContext context,
  required String normalizedCode,
  required bool isOnline,
}) {
  final days = PendingRetention.unverifiedPending.inDays;
  return showDialog<UnknownSessionCodeConfirmChoice>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final maxHeight = MediaQuery.sizeOf(ctx).height * 0.82;
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 400, maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.pin_outlined,
                        color: theme.colorScheme.primary,
                        size: 32,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Session code not found',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        isOnline
                            ? 'We could not find an active session for this code yet.'
                            : 'You are offline and this code is not on this device yet.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textSecondary,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppTheme.primary.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Text(
                          normalizedCode,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: 4,
                            color: AppTheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Is this the code your lecturer displayed?',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'If yes, we save it for up to $days days and auto-verify '
                        'when the session appears (including offline lecturer start).',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(
                        UnknownSessionCodeConfirmChoice.codeIsCorrect,
                      ),
                      child: const Text('Yes — save this code'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(
                        UnknownSessionCodeConfirmChoice.codeIsWrong,
                      ),
                      child: const Text('No — enter a different code'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
