import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// How to request U-Panel account deletion (mirrors website/delete-account.html).
class DeleteAccountScreen extends StatelessWidget {
  const DeleteAccountScreen({super.key});

  static const String lastUpdated = 'June 2026';

  @override
  Widget build(BuildContext context) {
    final bodyStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          height: 1.5,
          color: AppTheme.textPrimary,
        );
    final headingStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: AppTheme.textPrimary,
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Delete account'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text(
            'Last updated: $lastUpdated',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
          const SizedBox(height: 16),
          Text(
            'This page explains how to request deletion of your U-Panel sign-in '
            'account and related data held in the App.',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),
          _Section(
            title: 'Before you request deletion',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            paragraphs: [
              'U-Panel accounts are tied to your enrollment or employment at KIU. '
                  'Deleting your account removes App access; it does not withdraw you '
                  'from the university.',
              'Attendance records already submitted for academic purposes may be '
                  'retained as required by KIU policy or law.',
            ],
          ),
          _Section(
            title: 'What we delete',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            bullets: [
              'your U-Panel sign-in account.',
              'App user profile (name, email, registration or staff ID, role).',
              'Push notification tokens and subscriptions.',
              'Other personal app data not required for academic or legal reasons.',
            ],
          ),
          _Section(
            title: 'What may be retained',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            bullets: [
              'Attendance and sign-in records linked to courses and sessions.',
              'Aggregated or anonymized statistics.',
              'Security and audit logs for a limited period.',
            ],
          ),
          _Section(
            title: 'How to request deletion',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            paragraphs: [
              'Contact KIU through official channels and include your full name, '
                  'sign-in email or staff KIU-#### ID, faculty or department, and '
                  'a clear request to delete your U-Panel account.',
            ],
            bullets: [
              'Faculty or department office — ask them to forward to ICT or the '
                  'U-Panel administrator.',
              'University ICT support — use official KIU contact channels.',
              'On campus — visit your faculty office or ICT help desk with ID.',
            ],
          ),
          _Section(
            title: 'Processing time',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            paragraphs: [
              'Verified requests are typically processed within 30 days. You may '
                  'be asked to confirm your identity first.',
            ],
          ),
          _Section(
            title: 'After deletion',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            bullets: [
              'You cannot sign in unless an administrator creates a new account.',
              'Uninstalling the App does not delete server-side data.',
            ],
          ),
          _Section(
            title: 'Privacy policy',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            paragraphs: [
              'For more on how data is collected and used, open Privacy Policy '
                  'from Settings → About.',
            ],
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.bodyStyle,
    required this.headingStyle,
    this.paragraphs = const [],
    this.bullets = const [],
  });

  final String title;
  final TextStyle? bodyStyle;
  final TextStyle? headingStyle;
  final List<String> paragraphs;
  final List<String> bullets;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: headingStyle),
          const SizedBox(height: 8),
          for (final p in paragraphs) ...[
            Text(p, style: bodyStyle),
            const SizedBox(height: 8),
          ],
          if (bullets.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final b in bullets)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('• ', style: bodyStyle),
                          Expanded(child: Text(b, style: bodyStyle)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
