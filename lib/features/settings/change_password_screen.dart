import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/auth/staff_auth_email.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/dismissible_error_banner.dart';
import '../auth/forgot_password_screen.dart';
import '../../core/api/api_auth.dart';

enum _ChangePasswordPhase { form, processing, success }

/// Change password for the signed-in account.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _currentC = TextEditingController();
  final _newC = TextEditingController();
  final _confirmC = TextEditingController();
  final _currentFocus = FocusNode();
  final _newFocus = FocusNode();
  final _confirmFocus = FocusNode();

  _ChangePasswordPhase _phase = _ChangePasswordPhase.form;
  int _stageIndex = 0;
  String? _submitError;
  late final AnimationController _successController;
  late final Animation<double> _successScale;

  static const _processingStages = <String>[
    'Verifying your current password…',
    'Updating your new password…',
    'Securing your account…',
  ];

  @override
  void initState() {
    super.initState();
    _successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _successScale = CurvedAnimation(
      parent: _successController,
      curve: Curves.elasticOut,
    );
  }

  @override
  void dispose() {
    _successController.dispose();
    _currentC.dispose();
    _newC.dispose();
    _confirmC.dispose();
    _currentFocus.dispose();
    _newFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  String? _validateCurrent(String? value) {
    if (_phase != _ChangePasswordPhase.form) return null;
    if (value == null || value.isEmpty) {
      return 'Enter your current password.';
    }
    return null;
  }

  String? _validateNew(String? value) {
    if (_phase != _ChangePasswordPhase.form) return null;
    if (value == null || value.isEmpty) {
      return 'Enter a new password.';
    }
    if (value.length < 6) {
      return 'Use at least 6 characters.';
    }
    if (value == _currentC.text) {
      return 'Must be different from your current password.';
    }
    return null;
  }

  String? _validateConfirm(String? value) {
    if (_phase != _ChangePasswordPhase.form) return null;
    if (value == null || value.isEmpty) {
      return 'Confirm your new password.';
    }
    if (value != _newC.text) {
      return 'Passwords do not match.';
    }
    return null;
  }

  Future<void> _advanceProcessingStages() async {
    for (var i = 1; i < _processingStages.length; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 280));
      if (!mounted || _phase != _ChangePasswordPhase.processing) return;
      setState(() => _stageIndex = i);
    }
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() => _submitError = null);
    if (!_formKey.currentState!.validate()) return;

    if (AppConnectivity.instance.initialized &&
        !AppConnectivity.instance.isOnline) {
      setState(
        () => _submitError = AuthRepository.networkUnavailableMessage,
      );
      return;
    }

    setState(() {
      _phase = _ChangePasswordPhase.processing;
      _stageIndex = 0;
      _submitError = null;
    });

    final changeFuture = AuthRepository.instance.changePassword(
      currentPassword: _currentC.text,
      newPassword: _newC.text,
    );
    unawaited(_advanceProcessingStages());
    final err = await changeFuture;
    if (!mounted) return;

    if (err != null) {
      setState(() {
        _phase = _ChangePasswordPhase.form;
        _submitError = err;
      });
      return;
    }

    _currentC.clear();
    _newC.clear();
    _confirmC.clear();
    _formKey.currentState?.reset();

    setState(() => _phase = _ChangePasswordPhase.success);
    unawaited(_successController.forward(from: 0));
  }

  String? get _accountLabel {
    final auth = AuthRepository.instance;
    final staff = auth.currentStaffNumber?.trim();
    if (staff != null && staff.isNotEmpty) return staff;
    final email = auth.currentUserEmail ?? auth.currentEmail;
    if (email != null && email.trim().isNotEmpty) return email.trim();
    final authEmail = ApiAuth.instance.currentUser?.email;
    if (authEmail != null) {
      return StaffAuthEmail.syntheticEmailToStaffNumber(authEmail) ??
          authEmail;
    }
    return null;
  }

  Future<void> _openForgotPassword() async {
    final auth = AuthRepository.instance;
    final candidates = <String?>[
      auth.currentUserEmail,
      auth.currentEmail,
      ApiAuth.instance.currentUser?.email,
    ];
    String? initial;
    for (final candidate in candidates) {
      final trimmed = candidate?.trim();
      if (trimmed == null || trimmed.isEmpty) continue;
      if (StaffAuthEmail.syntheticEmailToStaffNumber(trimmed) != null) continue;
      if (AuthRepository.validateLoginEmailFormat(trimmed) == null) {
        initial = trimmed;
        break;
      }
    }
    if (initial != null && initial.isNotEmpty) {
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ForgotPasswordScreen(initialEmail: initial!),
        ),
      );
      return;
    }
    final staff = auth.currentStaffNumber?.trim();
    if (staff != null && staff.isNotEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Staff (KIU-####) accounts cannot reset by email. '
            'Use your current password above, or ask an administrator.',
          ),
        ),
      );
      return;
    }
    final fallbackInitial = auth.currentUserEmail ?? auth.currentEmail ?? '';
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ForgotPasswordScreen(initialEmail: fallbackInitial),
      ),
    );
  }

  void _finish() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final accountLabel = _accountLabel;
    final theme = Theme.of(context);

    return PopScope(
      canPop: _phase != _ChangePasswordPhase.processing,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Change password'),
          automaticallyImplyLeading: _phase != _ChangePasswordPhase.processing,
        ),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: switch (_phase) {
              _ChangePasswordPhase.form => _buildForm(
                  key: const ValueKey('form'),
                  accountLabel: accountLabel,
                  theme: theme,
                ),
              _ChangePasswordPhase.processing => _buildProcessing(
                  key: const ValueKey('processing'),
                  theme: theme,
                ),
              _ChangePasswordPhase.success => _buildSuccess(
                  key: const ValueKey('success'),
                  theme: theme,
                ),
            },
          ),
        ),
      ),
    );
  }

  Widget _buildForm({
    required Key key,
    required String? accountLabel,
    required ThemeData theme,
  }) {
    return SingleChildScrollView(
      key: key,
      padding: const EdgeInsets.all(20),
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.disabled,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (accountLabel != null) ...[
              Text(
                'Account',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                accountLabel,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              'Enter your current password, then choose a new one.',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 16),
            if (_submitError != null) ...[
              DismissibleErrorBanner(
                message: _submitError!,
                onDismiss: () => setState(() => _submitError = null),
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: _currentC,
              focusNode: _currentFocus,
              autofocus: true,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.next,
              onFieldSubmitted: (_) =>
                  FocusScope.of(context).requestFocus(_newFocus),
              validator: _validateCurrent,
              decoration: const InputDecoration(
                labelText: 'Current password',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _newC,
              focusNode: _newFocus,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.next,
              onFieldSubmitted: (_) =>
                  FocusScope.of(context).requestFocus(_confirmFocus),
              validator: _validateNew,
              decoration: const InputDecoration(
                labelText: 'New password',
                helperText: 'At least 6 characters',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _confirmC,
              focusNode: _confirmFocus,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              validator: _validateConfirm,
              decoration: const InputDecoration(
                labelText: 'Confirm new password',
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _submit,
              child: const Text('Change password'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _openForgotPassword,
              child: const Text('Forgot current password? Send reset link'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessing({required Key key, required ThemeData theme}) {
    return Center(
      key: key,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: AppTheme.primary,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Changing password',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      minHeight: 5,
                      backgroundColor: AppTheme.softGrey,
                      color: AppTheme.primary,
                    ),
                  ),
                  const SizedBox(height: 18),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: Text(
                      _processingStages[_stageIndex],
                      key: ValueKey<int>(_stageIndex),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppTheme.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSuccess({required Key key, required ThemeData theme}) {
    return Center(
      key: key,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ScaleTransition(
                    scale: _successScale,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: AppTheme.success.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check_rounded,
                        size: 42,
                        color: AppTheme.success,
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Password changed',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Your password has been updated successfully. '
                    'Use your new password the next time you sign in.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _finish,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Done'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

