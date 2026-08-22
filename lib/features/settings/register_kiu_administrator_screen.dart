import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/auth/kiu_admin_job_title.dart';
import '../../core/auth/kiu_admin_registration_number.dart';
import '../../core/auth/kiu_staff_auth_email.dart';
import '../../core/theme/app_theme.dart';

/// Full administrators: create a KIU administrator ([@kiu.ac.ug] or ICT exception).
class RegisterKiuAdministratorScreen extends StatefulWidget {
  const RegisterKiuAdministratorScreen({
    super.key,
    this.initialEmail,
  });

  final String? initialEmail;

  @override
  State<RegisterKiuAdministratorScreen> createState() =>
      _RegisterKiuAdministratorScreenState();
}

class _RegisterKiuAdministratorScreenState
    extends State<RegisterKiuAdministratorScreen> {
  final _fullNameC = TextEditingController();
  final _emailC = TextEditingController();
  final _regC = TextEditingController();
  final _passwordC = TextEditingController();
  final _roleC = TextEditingController();
  bool _busy = false;
  bool? _isKiuAdministrator;
  bool _passwordVisible = false;

  @override
  void initState() {
    super.initState();
    final seed = widget.initialEmail?.trim();
    if (seed != null && seed.isNotEmpty) {
      _emailC.text = seed;
    }
  }

  @override
  void dispose() {
    _fullNameC.dispose();
    _emailC.dispose();
    _regC.dispose();
    _passwordC.dispose();
    _roleC.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_busy) return;

    final name = _fullNameC.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the administrator\'s name.')),
      );
      return;
    }

    final isKiuAdministrator = _isKiuAdministrator;
    if (isKiuAdministrator == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select account type: KIU administrator or staff.'),
        ),
      );
      return;
    }

    setState(() => _busy = true);
    final result =
        await AuthRepository.instance.registerKiuAdministratorWithRealEmail(
      fullName: name,
      email: _emailC.text.trim(),
      registrationNumber: _regC.text.trim(),
      password: _passwordC.text,
      isKiuAdministrator: isKiuAdministrator,
      kiuAdminJobTitle: isKiuAdministrator ? _roleC.text : null,
    );
    if (!mounted) return;
    setState(() => _busy = false);

    if (result.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error!)),
      );
      return;
    }

    final reg = result.registrationNumber ?? '—';
    final roleLabel =
        isKiuAdministrator ? 'KIU administrator' : 'Staff (lecturer)';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$roleLabel created'),
        content: Text(
          'Registration: $reg\n'
          'Email: ${_emailC.text.trim()}\n\n'
          'They can sign in immediately. '
          '${KiuStaffAuthEmail.skipsVerification(_emailC.text.trim()) ? 'Email verification is skipped for this address.' : 'They must verify their @kiu.ac.ug email before using the app.'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Register KIU staff'),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: ListenableBuilder(
        listenable: AuthRepository.instance,
        builder: (context, _) {
          final auth = AuthRepository.instance;
          if (!auth.adminCheckDone) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!auth.isFullAdministrator) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Only full administrators can register KIU administrators.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final isKiuAdministrator = _isKiuAdministrator;
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Creates a @${KiuStaffAuthEmail.staffEmailDomain} account. Choose '
                'KIU administrator (campus check-in required) or staff lecturer.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.4,
                    ),
              ),
              const SizedBox(height: 20),
              Text(
                'Account type',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                emptySelectionAllowed: true,
                segments: const [
                  ButtonSegment(
                    value: true,
                    label: Text('KIU administrator'),
                    icon: Icon(Icons.admin_panel_settings_outlined),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text('Staff'),
                    icon: Icon(Icons.person_outline_rounded),
                  ),
                ],
                selected: isKiuAdministrator == null
                    ? const <bool>{}
                    : {isKiuAdministrator},
                onSelectionChanged: _busy
                    ? null
                    : (selection) {
                        setState(() => _isKiuAdministrator = selection.first);
                      },
              ),
              const SizedBox(height: 8),
              Text(
                isKiuAdministrator == null
                    ? 'Select KIU administrator or staff lecturer for this account.'
                    : isKiuAdministrator
                        ? 'Campus check-in required · attendance lists · presence log.'
                        : 'Staff lecturer · attendance lists · no campus check-in.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.35,
                    ),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _fullNameC,
                decoration: const InputDecoration(
                  labelText: 'Full name',
                  hintText: 'e.g. Jane Doe',
                ),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _emailC,
                decoration: InputDecoration(
                  labelText: 'Email',
                  hintText: KiuStaffAuthEmail.exampleEmail,
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _regC,
                decoration: InputDecoration(
                  labelText: 'Registration number',
                  hintText: KiuAdminRegistrationNumber.example,
                ),
                textCapitalization: TextCapitalization.characters,
              ),
              if (isKiuAdministrator == true) ...[
                const SizedBox(height: 16),
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
                        selection: TextSelection.collapsed(
                          offset: upper.length,
                        ),
                      );
                    }
                  },
                ),
              ],
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordC,
                decoration: InputDecoration(
                  labelText: 'Initial password',
                  suffixIcon: IconButton(
                    tooltip:
                        _passwordVisible ? 'Hide password' : 'Show password',
                    onPressed: _busy
                        ? null
                        : () => setState(
                            () => _passwordVisible = !_passwordVisible),
                    icon: Icon(
                      _passwordVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
                obscureText: !_passwordVisible,
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed:
                    (_busy || isKiuAdministrator == null) ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        isKiuAdministrator == true
                            ? 'Create KIU administrator'
                            : 'Create staff account',
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
