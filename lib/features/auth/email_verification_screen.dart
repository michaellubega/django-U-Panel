import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/auth/kiu_staff_auth_email.dart';
import '../../core/navigation/app_navigator.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/dismissible_error_banner.dart';

/// Blocks app access until a KIU student or staff mailbox is verified.
class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key});

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen>
    with WidgetsBindingObserver {
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AuthRepository.instance.addListener(_onAuthChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_tryAlreadyVerified(silent: true));
      _showSignupVerificationHintIfNeeded();
    });
  }

  void _showSignupVerificationHintIfNeeded() {
    final auth = AuthRepository.instance;
    if (!auth.shouldShowEmailVerificationUi) return;
    if (auth.verificationEmailQueuedAtSignup) {
      auth.clearVerificationEmailQueuedAtSignup();
      if (!mounted) return;
      setState(() {
        _status =
            'Verification email sent. Check your inbox and Spam/Junk folder.';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AuthRepository.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_tryAlreadyVerified(silent: true));
    }
  }

  void _onAuthChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _clearProfileError() {
    AuthRepository.instance.clearAuthFormError();
  }

  String get _email =>
      AuthRepository.instance.currentUserEmail ?? 'your email';

  /// Picks up verification done outside the app (email link in browser).
  Future<void> _tryAlreadyVerified({bool silent = false}) async {
    if (_busy) return;
    final auth = AuthRepository.instance;
    final mailboxEmail = auth.currentEmail ?? _email;
    if (KiuStaffAuthEmail.skipsVerification(mailboxEmail)) {
      return;
    }
    if (!silent) {
      setState(() {
        _busy = true;
        _status = null;
      });
    }
    final verified =
        await AuthRepository.instance.refreshStudentEmailVerified();
    if (!mounted) return;
    if (!silent) {
      setState(() => _busy = false);
    }
    if (verified) return;
    if (!silent) {
      setState(() {
        _status =
            'Email not verified yet. Open the verification link we sent to $_email '
            '(check Spam/Junk and use Not spam if needed so the link opens), then tap again.';
      });
    }
  }

  Future<void> _resend() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    final err = await AuthRepository.instance.sendEmailVerificationForCurrentUser();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = err == null
          ? 'Verification email sent. Check your inbox and Spam/Junk; if it is in spam, mark Not spam so the link works.'
          : err;
    });
  }

  Future<void> _checkVerified() async => _tryAlreadyVerified();

  Future<void> _signOut() async {
    final err = await AuthRepository.instance.logout();
    if (err != null) {
      showRootSnackBar(err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: AppTheme.surface,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.mark_email_unread_outlined,
                    size: 56,
                    color: AppTheme.primary.withValues(alpha: 0.9),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Verify your email',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'We sent a verification link to:',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _email,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Open that email on this device (or any device signed into the same mailbox), tap the verification link, then return here and continue.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.accentLight.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.2),
                      ),
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
                            'If you do not see the message in your inbox within a few minutes, '
                            'check your Spam or Junk folder. If you find it there, mark it as '
                            'Not spam (or Not junk) so the verification link opens and future '
                            'messages from U-Panel reach your inbox.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AppTheme.textPrimary,
                              height: 1.4,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Builder(
                    builder: (context) {
                      final profileError = AuthRepository.instance
                          .authFormErrorMessage
                          ?.trim();
                      if (profileError == null || profileError.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 16),
                          DismissibleErrorBanner(
                            message: profileError,
                            onDismiss: _clearProfileError,
                          ),
                        ],
                      );
                    },
                  ),
                  if (_status != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _status!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _status!.startsWith('Verification email')
                            ? AppTheme.primary
                            : AppTheme.error,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: _busy ? null : _checkVerified,
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
                        : const Text('I verified my email — continue'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _busy ? null : _resend,
                    child: const Text('Resend verification email'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy ? null : _signOut,
                    child: const Text('Sign out'),
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
