import 'package:flutter/material.dart';
import '../../core/auth/auth_action_result.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/auth/staff_auth_email.dart';
import '../../core/auth/student_auth_email.dart';
import '../../core/auth/student_registration_number.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/navigation/app_navigator.dart';
import '../../core/theme/app_theme.dart';
import 'forgot_password_screen.dart';

/// Email + password sign-in and registration (Firebase Auth).
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailC = TextEditingController();
  final _fullNameC = TextEditingController();
  final _regC = TextEditingController();
  final _passwordC = TextEditingController();
  final _confirmC = TextEditingController();
  bool _register = false;
  bool _busy = false;
  /// When true, password fields show plain text (single toggle for both).
  bool _passwordVisible = false;

  @override
  void dispose() {
    _emailC.dispose();
    _fullNameC.dispose();
    _regC.dispose();
    _passwordC.dispose();
    _confirmC.dispose();
    super.dispose();
  }

  bool get _studentEmailOk =>
      StudentAuthEmail.validateFormat(_emailC.text) == null;

  String? get _studentEmailError {
    if (!_register) return null;
    final raw = _emailC.text.trim();
    if (raw.isEmpty) return null;
    return StudentAuthEmail.validateFormat(_emailC.text);
  }

  bool get _loginIdOk {
    final raw = _emailC.text.trim();
    if (raw.isEmpty) return false;
    if (StaffAuthEmail.looksLikeStaffNumberOnly(raw)) {
      return StaffAuthEmail.normalizeStaffNumber(raw) != null;
    }
    final resolved = StaffAuthEmail.resolveLoginEmail(raw) ?? '';
    if (!resolved.contains('@')) return false;
    if (StaffAuthEmail.syntheticEmailToStaffNumber(resolved) != null) {
      return true;
    }
    return StudentAuthEmail.validateLoginFormat(raw) == null;
  }

  bool get _regOk =>
      StudentRegistrationNumber.validateFormat(_regC.text) == null;

  bool get _fullNameOk => _fullNameC.text.trim().isNotEmpty;

  bool get _canSubmitLogin =>
      _loginIdOk && _passwordC.text.isNotEmpty && !_busy;

  bool get _canSubmitRegister =>
      _studentEmailOk &&
      _fullNameOk &&
      _regOk &&
      _passwordC.text.length >= 6 &&
      _passwordC.text == _confirmC.text &&
      !_busy;

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      if (!mounted) return;
      final AuthActionResult? result =
          await Navigator.of(context).push<AuthActionResult>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _LoginVerificationScreen(
            registering: _register,
            email: _emailC.text,
            fullName: _fullNameC.text.trim(),
            password: _passwordC.text,
            registrationNumber: _regC.text.trim(),
          ),
        ),
      );
      if (!mounted) return;
      final err = result?.error;
      if (err == null || err.isEmpty) return;
      if (AuthRepository.instance.studentRegistrationConflictMessage == err) {
        return;
      }
      showRootSnackBar(err, duration: const Duration(seconds: 7), isError: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  InputDecoration _passwordDecoration(String label) {
    final obscure = !_passwordVisible;
    return InputDecoration(
      labelText: label,
      suffixIcon: IconButton(
        tooltip: _passwordVisible ? 'Hide password' : 'Show password',
        icon: Icon(
          obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          color: AppTheme.textSecondary,
        ),
        onPressed: () => setState(() => _passwordVisible = !_passwordVisible),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final obscurePasswords = !_passwordVisible;

    return Scaffold(
      backgroundColor: AppTheme.surface,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: ListenableBuilder(
              listenable: AppConnectivity.instance,
              builder: (context, _) {
                final offline = AppConnectivity.instance.initialized &&
                    !AppConnectivity.instance.isOnline;
                return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (offline) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppTheme.error.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.wifi_off_rounded,
                            color: AppTheme.error,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              AuthRepository.networkUnavailableMessage,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: AppTheme.textPrimary,
                                    height: 1.4,
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    'KIU',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4,
                      color: AppTheme.accent,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Kampala International University',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                  ),
                  const SizedBox(height: 28),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Log in')),
                      ButtonSegment(value: true, label: Text('Create account')),
                    ],
                    selected: {_register},
                    onSelectionChanged: (s) {
                      setState(() => _register = s.first);
                    },
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _register
                        ? 'Use your official KIU student email (@studmc.kiu.ac.ug), full name, registration number, and password.'
                        : 'Sign in with your email and password.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppTheme.softGrey),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: _emailC,
                          decoration: InputDecoration(
                            labelText: _register ? 'KIU school email' : 'Email or staff ID',
                            hintText: _register
                                ? StudentAuthEmail.exampleEmail
                                : 'e.g. ${StudentAuthEmail.exampleEmail} or KIU-0001',
                            errorText: _studentEmailError,
                            errorMaxLines: 4,
                          ),
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          textInputAction: TextInputAction.next,
                          onChanged: (_) => setState(() {}),
                        ),
                        if (_register &&
                            _studentEmailError == null &&
                            _emailC.text.trim().isEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Only your official KIU student mailbox (@${StudentAuthEmail.studentEmailDomain}) can be used — not Gmail, Yahoo, or other personal email.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textSecondary,
                                  height: 1.35,
                                ),
                          ),
                        ],
                        if (!_register) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Lecturers: enter your KIU-#### ID and your password.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textSecondary,
                                ),
                          ),
                        ],
                        if (_register && _studentEmailOk) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Format: firstname.lastname@${StudentAuthEmail.studentEmailDomain}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textSecondary,
                                ),
                          ),
                        ],
                        if (_register) ...[
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _fullNameC,
                            decoration: const InputDecoration(
                              labelText: 'Full name',
                              hintText: 'e.g. Jane Doe',
                            ),
                            textCapitalization: TextCapitalization.words,
                            autocorrect: false,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Registration: ${StudentRegistrationNumber.example} — each number is linked to one school email only.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textSecondary,
                                  height: 1.35,
                                ),
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _regC,
                            decoration: const InputDecoration(
                              labelText: 'Registration number',
                              hintText: StudentRegistrationNumber.example,
                            ),
                            keyboardType: TextInputType.text,
                            autocorrect: false,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) {
                              AuthRepository.instance
                                  .clearStudentRegistrationConflictMessage();
                              setState(() {});
                            },
                          ),
                        ],
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _passwordC,
                          decoration: _passwordDecoration('Password'),
                          obscureText: obscurePasswords,
                          textInputAction: _register
                              ? TextInputAction.next
                              : TextInputAction.done,
                          onChanged: (_) => setState(() {}),
                          onFieldSubmitted: (_) {
                            if (!_register &&
                                _canSubmitLogin &&
                                !_busy) {
                              _submit();
                            }
                          },
                        ),
                        if (!_register) ...[
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _busy
                                  ? null
                                  : () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) => ForgotPasswordScreen(
                                            initialEmail: _emailC.text,
                                          ),
                                        ),
                                      );
                                    },
                              child: const Text('Forgot password?'),
                            ),
                          ),
                        ],
                        if (_register) ...[
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _confirmC,
                            decoration: _passwordDecoration('Confirm password'),
                            obscureText: obscurePasswords,
                            textInputAction: TextInputAction.done,
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Password must be at least 6 characters.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textSecondary,
                                ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _busy
                              ? null
                              : (_register
                                  ? (_canSubmitRegister ? _submit : null)
                                  : (_canSubmitLogin ? _submit : null)),
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
                              : Text(_register ? 'Create account' : 'Log in'),
                        ),
                      ],
                    ),
                  ),
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
}

class _LoginVerificationScreen extends StatefulWidget {
  const _LoginVerificationScreen({
    required this.registering,
    required this.email,
    required this.fullName,
    required this.password,
    required this.registrationNumber,
  });

  final bool registering;
  final String email;
  final String fullName;
  final String password;
  final String registrationNumber;

  @override
  State<_LoginVerificationScreen> createState() =>
      _LoginVerificationScreenState();
}

class _LoginVerificationScreenState extends State<_LoginVerificationScreen> {
  int _stageIndex = 0;
  bool _done = false;
  String? _error;

  List<String> get _stages => widget.registering
      ? const <String>[
          'Authorizing account details...',
          'Creating your account...',
          'Sending verification email...',
        ]
      : const <String>[
          'Authorizing login details...',
          'Verifying user credentials...',
          'Signing you in...',
        ];

  @override
  void initState() {
    super.initState();
    _runAuthFlow();
  }

  Future<void> _runAuthFlow() async {
    await Future<void>.delayed(const Duration(milliseconds: 320));
    if (!mounted) return;
    setState(() => _stageIndex = 1);
    await Future<void>.delayed(const Duration(milliseconds: 360));
    if (!mounted) return;
    setState(() => _stageIndex = 2);
    final auth = AuthRepository.instance;
    final AuthActionResult result = widget.registering
        ? await auth.registerWithEmail(
            email: widget.email,
            fullName: widget.fullName,
            password: widget.password,
            registrationNumber: widget.registrationNumber,
          )
        : await auth.signInWithEmail(
            email: widget.email,
            password: widget.password,
          );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _error = result.error;
        _done = false;
        _stageIndex = _stages.length - 1;
      });
      return;
    }
    setState(() => _done = true);
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppTheme.surface,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.registering
                              ? 'Creating account'
                              : 'Verifying login',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 14),
                        if (_error != null) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.error.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: AppTheme.error.withValues(alpha: 0.45),
                              ),
                            ),
                            child: Text(
                              _error!,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: AppTheme.textPrimary,
                                    fontWeight: FontWeight.w600,
                                    height: 1.4,
                                  ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: () => Navigator.of(context).pop(
                                AuthActionResult(error: _error),
                              ),
                              child: const Text('Back to sign in'),
                            ),
                          ),
                        ] else ...[
                          LinearProgressIndicator(
                            minHeight: 5,
                            value: _done ? 1 : null,
                          ),
                          const SizedBox(height: 14),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            child: Text(
                              _stages[_stageIndex],
                              key: ValueKey<int>(_stageIndex),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
