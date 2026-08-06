import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// In-app privacy policy (mirrors website/privacy.html).
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

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
        title: const Text('Privacy Policy'),
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
            'U-Panel is operated for Kampala International University (KIU) '
            'to support class attendance, notices, and related university '
            'operations. This policy explains what information the App '
            'collects, how we use it, and the choices available to you.',
            style: bodyStyle,
          ),
          const SizedBox(height: 24),
          _Section(
            title: '1. Who this applies to',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            paragraphs: [
              'This policy applies to students, lecturers, and staff who sign '
                  'in to U-Panel using university-issued credentials.',
            ],
          ),
          _Section(
            title: '2. Information we collect',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            paragraphs: [
              'Depending on your role and how you use the App, we may process:',
            ],
            bullets: [
              'Account and profile data — sign-in email or staff identifier, '
                  'display name, registration number (students), role, and '
                  'related profile fields.',
              'Attendance data — session codes, course selections, check-in '
                  'timestamps, and attendance records linked to your account.',
              'Location data — approximate GPS coordinates for on-campus '
                  'check-ins. Remote sessions may not require location.',
              'Device information — an identifier to help enforce one '
                  'check-in per device per session.',
              'Notifications — push tokens and topic subscriptions for '
                  'class and university notices.',
              'Local app data — cached lists and pending check-ins stored '
                  'on your device when offline.',
              'Technical logs — basic diagnostic information from our '
                  'hosting providers.',
            ],
            trailing: 'We do not sell your personal information.',
          ),
          _Section(
            title: '3. How we use information',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            bullets: [
              'Authenticate you and provide role-based access.',
              'Record and display attendance for authorized sessions.',
              'Verify on-campus check-ins where location is required.',
              'Send and display notices and operational messages.',
              'Sync data after you reconnect from offline use.',
              'Maintain security and support the App.',
              'Comply with university policies and applicable law.',
            ],
          ),
          _Section(
            title: '4. Third-party services',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            paragraphs: [
              'U-Panel uses a Django REST API backend for authentication, '
                  'databases, storage, and related server services. Data '
                  'processed through the backend is subject to your '
                  'institution\'s policies and applicable law.',
            ],
          ),
          _Section(
            title: '5. Sharing of information',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            bullets: [
              'With authorized KIU staff and lecturers for attendance '
                  'administration.',
              'With service providers that process data on our behalf.',
              'When required by law or to protect users and the university.',
            ],
            trailing: 'We do not share personal data with advertisers.',
          ),
          _Section(
            title: '6. Retention and security',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            paragraphs: [
              'We retain records for academic and administrative purposes in '
                  'line with KIU policies. Local cached data can be removed by '
                  'clearing app data or uninstalling the App.',
              'We use encrypted connections, access controls, and role-based '
                  'permissions. Please use a strong password and keep your '
                  'device updated.',
            ],
          ),
          _Section(
            title: '7. Your choices',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            bullets: [
              'Turn off location or notifications in device settings.',
              'Sign out on shared devices.',
              'Contact KIU ICT or your faculty to correct data or ask '
                  'questions about how your information is handled.',
            ],
          ),
          _Section(
            title: '8. Contact',
            bodyStyle: bodyStyle,
            headingStyle: headingStyle,
            paragraphs: [
              'For privacy questions related to U-Panel, contact your faculty '
                  'office or Kampala International University ICT support '
                  'through official university channels.',
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
    this.trailing,
  });

  final String title;
  final TextStyle? bodyStyle;
  final TextStyle? headingStyle;
  final List<String> paragraphs;
  final List<String> bullets;
  final String? trailing;

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
          if (trailing != null) ...[
            const SizedBox(height: 8),
            Text(trailing!, style: bodyStyle),
          ],
        ],
      ),
    );
  }
}
