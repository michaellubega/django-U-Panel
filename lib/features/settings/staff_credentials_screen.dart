import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/auth/staff_auth_email.dart';
import '../../core/theme/app_theme.dart';

/// Shown after a staff or administrator account is created — share login details.
class StaffCredentialsScreen extends StatefulWidget {
  const StaffCredentialsScreen({
    super.key,
    required this.fullName,
    required this.roleLabel,
    required this.staffId,
    this.password = StaffAuthEmail.defaultLecturerPassword,
  });

  final String fullName;
  final String roleLabel;
  final String staffId;
  final String password;

  @override
  State<StaffCredentialsScreen> createState() => _StaffCredentialsScreenState();
}

class _StaffCredentialsScreenState extends State<StaffCredentialsScreen> {
  bool _passwordVisible = false;

  void _copy(BuildContext context, String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied'), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Account created'),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(Icons.check_circle_outline, size: 56, color: AppTheme.success),
          const SizedBox(height: 16),
          Text(
            '${widget.fullName} is ready',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Registered as ${widget.roleLabel}. Share these sign-in details securely — '
            'they should change the password under Settings after first login.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                  height: 1.4,
                ),
          ),
          const SizedBox(height: 28),
          _CredentialCard(
            label: 'Staff ID (sign-in username)',
            value: widget.staffId,
            onCopy: () => _copy(context, 'Staff ID', widget.staffId),
          ),
          const SizedBox(height: 16),
          _CredentialCard(
            label: 'Password',
            value: widget.password,
            obscure: !_passwordVisible,
            onToggleVisibility: () =>
                setState(() => _passwordVisible = !_passwordVisible),
            visibilityVisible: _passwordVisible,
            onCopy: () => _copy(context, 'Password', widget.password),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () {
              final bundle =
                  'Staff ID: ${widget.staffId}\nPassword: ${widget.password}\nRole: ${widget.roleLabel}';
              _copy(context, 'Login details', bundle);
            },
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Copy all'),
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

class _CredentialCard extends StatelessWidget {
  const _CredentialCard({
    required this.label,
    required this.value,
    required this.onCopy,
    this.obscure = false,
    this.onToggleVisibility,
    this.visibilityVisible = false,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;
  final bool obscure;
  final VoidCallback? onToggleVisibility;
  final bool visibilityVisible;

  @override
  Widget build(BuildContext context) {
    final displayValue = obscure ? '•' * value.length : value;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.softGrey),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: AppTheme.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: SelectableText(
                  displayValue,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: obscure ? 2 : 0.5,
                      ),
                ),
              ),
              if (onToggleVisibility != null)
                IconButton(
                  tooltip: visibilityVisible ? 'Hide password' : 'Show password',
                  onPressed: onToggleVisibility,
                  icon: Icon(
                    visibilityVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              IconButton(
                tooltip: 'Copy',
                onPressed: onCopy,
                icon: const Icon(Icons.copy_outlined),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
