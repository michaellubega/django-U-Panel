import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/auth/login_email.dart';
import '../../core/auth/student_auth_email.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/theme/app_theme.dart';

/// Request a Firebase password-reset link for a KIU student or staff email.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail = ''});

  final String initialEmail;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final TextEditingController _emailC;
  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _emailC = TextEditingController(text: widget.initialEmail);
  }

  @override
  void dispose() {
    _emailC.dispose();
    super.dispose();
  }

  String _normalizedLoginEmail(String raw) =>
      LoginEmail.normalizeForPasswordReset(raw);

  bool get _canSend =>
      AuthRepository.validateLoginEmailFormat(_emailC.text) == null &&
      !_busy &&
      !_sent;

  String? get _emailFieldError {
    if (_sent) return null;
    final raw = _emailC.text.trim();
    if (raw.isEmpty) return null;
    return AuthRepository.validateLoginEmailFormat(_emailC.text);
  }

  Future<void> _send() async {
    FocusScope.of(context).unfocus();
    final formatErr = AuthRepository.validateLoginEmailFormat(_emailC.text);
    if (formatErr != null) {
      setState(() => _error = formatErr);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await AuthRepository.instance.sendPasswordResetEmail(
      rawLogin: _emailC.text,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (err != null) {
        _error = err;
        _sent = false;
      } else {
        _sent = true;
        _error = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        title: const Text('Forgot password'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListenableBuilder(
              listenable: AppConnectivity.instance,
              builder: (context, _) {
                final offline = AppConnectivity.instance.initialized &&
                    !AppConnectivity.instance.isOnline;
                return SingleChildScrollView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (offline) ...[
                        Text(
                          AuthRepository.networkUnavailableMessage,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppTheme.error,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_sent) ...[
                        Icon(
                          Icons.mark_email_read_outlined,
                          size: 56,
                          color: AppTheme.primary.withValues(alpha: 0.9),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Check your email',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'If an account exists for ${_normalizedLoginEmail(_emailC.text)}, '
                          'we sent a password reset link. Open it to choose a new password, then return here to log in.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 14),
                        _spamHint(theme),
                        const SizedBox(height: 28),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Back to log in'),
                        ),
                      ] else ...[
                        Text(
                          'Enter your ${LoginEmail.supportedDomainsHint()} '
                          'We will send a link to reset your password.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: AppTheme.textSecondary,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Staff (KIU-####): use Settings → change password after sign-in, or ask an administrator.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextFormField(
                          controller: _emailC,
                          enabled: !offline,
                          decoration: InputDecoration(
                            labelText: 'KIU email',
                            hintText: StudentAuthEmail.exampleEmailWest,
                            errorText: _emailFieldError,
                            errorMaxLines: 4,
                          ),
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          textInputAction: TextInputAction.done,
                          onChanged: (_) => setState(() {}),
                          onFieldSubmitted: (_) {
                            if (_canSend && !offline) _send();
                          },
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AppTheme.error,
                              height: 1.4,
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: offline || !_canSend ? null : _send,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            foregroundColor: Colors.white,
                          ),
                          child: _busy
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Send reset link'),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _spamHint(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.accentLight.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 22,
            color: AppTheme.primary.withValues(alpha: 0.9),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Check Spam or Junk if the message is not in your inbox. If you find it there, '
              'mark it Not spam (or Not junk) so the reset link opens.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.textPrimary,
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
