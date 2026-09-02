import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/auth/user_role.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/admin_gate.dart';

/// Admin-only: create VC / DVC / DQA / Dean / HOD read-only accounts.
class RegisterOversightScreen extends StatefulWidget {
  const RegisterOversightScreen({super.key});

  @override
  State<RegisterOversightScreen> createState() => _RegisterOversightScreenState();
}

class _RegisterOversightScreenState extends State<RegisterOversightScreen> {
  final _nameC = TextEditingController();
  final _emailC = TextEditingController();
  final _passwordC = TextEditingController();
  final _staffC = TextEditingController();
  UserRole _role = UserRole.dean;
  bool _busy = false;

  static const _roles = [
    UserRole.vc,
    UserRole.dvc,
    UserRole.dqa,
    UserRole.dean,
    UserRole.hod,
  ];

  @override
  void dispose() {
    _nameC.dispose();
    _emailC.dispose();
    _passwordC.dispose();
    _staffC.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final result = await AuthRepository.instance.registerOversightAccount(
      fullName: _nameC.text,
      role: _role,
      email: _emailC.text,
      password: _passwordC.text,
      staffNumber: _staffC.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error!)),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${_role.label} account created.')),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AdminGate(
      title: 'Leadership accounts',
      child: Scaffold(
        backgroundColor: AppTheme.surface,
        appBar: AppBar(title: const Text('Add leadership account')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            const Text(
              'These accounts see QAAT-style dashboards of attendance already '
              'captured. They cannot start sessions or change rolls.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<UserRole>(
              initialValue: _role,
              decoration: const InputDecoration(labelText: 'Role'),
              items: [
                for (final r in _roles)
                  DropdownMenuItem(value: r, child: Text(r.label)),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _role = v);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameC,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Full name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _emailC,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordC,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Temporary password'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _staffC,
              decoration: const InputDecoration(
                labelText: 'Staff ID (optional)',
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create account'),
            ),
          ],
        ),
      ),
    );
  }
}
