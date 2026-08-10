import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/auth/kiu_admin_job_title.dart';
import '../../core/auth/kiu_admin_registration_number.dart';
import '../../core/auth/kiu_staff_auth_email.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/dismissible_error_banner.dart';

/// Staff self-registration with @kiu.ac.ug email and staff ID (e.g. KIU4235S).
class KiuStaffRegisterScreen extends StatefulWidget {
  const KiuStaffRegisterScreen({super.key});

  @override
  State<KiuStaffRegisterScreen> createState() => _KiuStaffRegisterScreenState();
}

class _KiuStaffRegisterScreenState extends State<KiuStaffRegisterScreen> {
  final _fullNameC = TextEditingController();
  final _emailC = TextEditingController();
  final _regC = TextEditingController();
  final _passwordC = TextEditingController();
  final _roleC = TextEditingController();
  bool _busy = false;
  bool? _isKiuAdministrator;
  bool _passwordVisible = false;
  String? _formError;

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

    final isKiuAdministrator = _isKiuAdministrator;
    if (isKiuAdministrator == null) {
      setState(() {
        _formError = 'Select account type: KIU administrator or staff.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _formError = null;
    });
    final result = await AuthRepository.instance.registerKiuStaffWithEmail(
      email: _emailC.text.trim(),
      fullName: _fullNameC.text.trim(),
      password: _passwordC.text,
      registrationNumber: _regC.text.trim(),
      isKiuAdministrator: isKiuAdministrator,
      kiuAdminJobTitle: isKiuAdministrator ? _roleC.text : null,
    );
    if (!mounted) return;
    setState(() => _busy = false);

    if (result.error != null) {
      setState(() => _formError = result.error);
      return;
    }

    if (!mounted) return;
    if (result.needsEmailVerification) {
      AuthRepository.instance.clearAuthFormDraft();
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Account created. You can sign in now.')),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isKiuAdministrator = _isKiuAdministrator;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff registration'),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Use your official @${KiuStaffAuthEmail.staffEmailDomain} email and '
            'staff ID (e.g. ${KiuAdminRegistrationNumber.example}).',
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
                ? 'Select whether you are a KIU administrator or staff lecturer.'
                : isKiuAdministrator
                    ? 'Campus check-in required. Can run attendance lists and appears in the administrator presence log.'
                    : 'Lecturer staff account. Can run attendance lists. No campus check-in requirement.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                  height: 1.35,
                ),
          ),
          const SizedBox(height: 24),
          TextFormField(
            controller: _fullNameC,
            decoration: const InputDecoration(labelText: 'Full name'),
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _emailC,
            decoration: InputDecoration(
              labelText: 'KIU staff email',
              hintText: KiuStaffAuthEmail.exampleEmail,
            ),
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _regC,
            decoration: InputDecoration(
              labelText: 'Staff ID',
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
                    selection: TextSelection.collapsed(offset: upper.length),
                  );
                }
              },
            ),
          ],
          const SizedBox(height: 16),
          TextFormField(
            controller: _passwordC,
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                tooltip: _passwordVisible ? 'Hide password' : 'Show password',
                onPressed: _busy
                    ? null
                    : () =>
                        setState(() => _passwordVisible = !_passwordVisible),
                icon: Icon(
                  _passwordVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
            obscureText: !_passwordVisible,
          ),
          if (_formError != null && _formError!.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            DismissibleErrorBanner(
              message: _formError!,
              dismissEnabled: !_busy,
              onDismiss: () => setState(() => _formError = null),
            ),
          ],
          const SizedBox(height: 28),
          FilledButton(
            onPressed: (_busy || isKiuAdministrator == null) ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    isKiuAdministrator == true
                        ? 'Create administrator account'
                        : 'Create staff account',
                  ),
          ),
        ],
      ),
    );
  }
}
