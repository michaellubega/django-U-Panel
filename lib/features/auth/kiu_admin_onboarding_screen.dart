import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/auth/kiu_admin_job_title.dart';
import '../../core/theme/app_theme.dart';

/// After @kiu.ac.ug email verification — confirm KIU administrator role.
class KiuAdminOnboardingScreen extends StatefulWidget {
  const KiuAdminOnboardingScreen({super.key});

  @override
  State<KiuAdminOnboardingScreen> createState() =>
      _KiuAdminOnboardingScreenState();
}

class _KiuAdminOnboardingScreenState extends State<KiuAdminOnboardingScreen> {
  bool _busy = false;
  final _roleC = TextEditingController();

  @override
  void dispose() {
    _roleC.dispose();
    super.dispose();
  }

  Future<void> _answer(bool isKiuAdministrator) async {
    if (_busy) return;
    setState(() => _busy = true);
    final err = await AuthRepository.instance.completeKiuAdminOnboarding(
      isKiuAdministrator: isKiuAdministrator,
      kiuAdminJobTitle: isKiuAdministrator ? _roleC.text : null,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err)),
      );
      return;
    }
    if (!isKiuAdministrator) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Staff account ready. You can run attendance lists as a lecturer.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('KIU administrator'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              Icons.admin_panel_settings_rounded,
              size: 56,
              color: AppTheme.primary.withValues(alpha: 0.9),
            ),
            const SizedBox(height: 20),
            Text(
              'Are you a KIU administrator?',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Choose whether you are a KIU administrator (campus check-in required) '
              'or staff lecturer (attendance lists only).',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: AppTheme.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 32),
            TextFormField(
              controller: _roleC,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Admin role (optional)',
                hintText: 'DIRECTOR QUALITY ASSURANCE',
                helperText: KiuAdminJobTitle.examplesLine,
              ),
              textCapitalization: TextCapitalization.characters,
              onChanged: (v) {
                final upper = v.toUpperCase();
                if (v != upper) {
                  _roleC.value = _roleC.value.copyWith(
                    text: upper,
                    selection: TextSelection.collapsed(offset: upper.length),
                  );
                }
              },
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : () => _answer(true),
              child: _busy
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Yes — I am a KIU administrator'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : () => _answer(false),
              child: const Text('Staff — lecturer only'),
            ),
          ],
        ),
      ),
    );
  }
}
