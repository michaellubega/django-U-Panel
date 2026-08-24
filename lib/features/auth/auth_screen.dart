import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/api/api_config.dart';
import '../../core/auth/auth_action_result.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/auth/staff_auth_email.dart';
import 'kiu_staff_register_screen.dart';
import '../../core/auth/kiu_admin_registration_number.dart';
import '../../core/auth/kiu_staff_auth_email.dart';
import '../../core/auth/student_auth_email.dart';
import '../../core/auth/student_registration_number.dart';
import '../../core/connectivity/app_connectivity.dart';
import '../../core/navigation/app_navigator.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_brand_logo.dart';
import '../../core/widgets/dismissible_error_banner.dart';
import '../../core/widgets/web_build_label.dart';
import 'forgot_password_screen.dart';

/// Email + password sign-in and registration (Django API).
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _scrollC = ScrollController();
  final _errorKey = GlobalKey();
  final _emailC = TextEditingController();
  final _fullNameC = TextEditingController();
  final _regC = TextEditingController();
  final _passwordC = TextEditingController();
  final _confirmC = TextEditingController();
  bool _register = false;
  bool _busy = false;
  /// When true, password fields show plain text (single toggle for both).
  bool _passwordVisible = false;
  bool _offlineBannerDismissed = false;
  /// Required when create-account details look like @kiu.ac.ug + KIU staff ID.
  /// `true` = student, `false` = lecturer, `null` = not chosen yet.
  bool? _signupAsStudent;

  @override
  void initState() {
    super.initState();
    final draft = AuthRepository.instance.authFormDraft;
    _emailC.text = draft.email;
    _fullNameC.text = draft.fullName;
    _regC.text = draft.registrationNumber;
    _register = draft.registering;
    _emailC.addListener(_persistDraft);
    _fullNameC.addListener(_persistDraft);
    _regC.addListener(_persistDraft);
    AppConnectivity.instance.addListener(_onConnectivityChanged);
    AuthRepository.instance.addListener(_onAuthFormErrorChanged);
  }

  void _persistDraft() {
    AuthRepository.instance.updateAuthFormDraft(
      email: _emailC.text,
      fullName: _fullNameC.text,
      registrationNumber: _regC.text,
      registering: _register,
    );
  }

  void _onAuthFormErrorChanged() {
    if (!mounted) return;
    final msg = AuthRepository.instance.authFormErrorMessage?.trim();
    setState(() {});
    if (msg == null || msg.isEmpty) return;
    showRootSnackBar(
      msg,
      isError: true,
      duration: const Duration(seconds: 6),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _errorKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: 0.35,
        );
      }
    });
  }

  void _onConnectivityChanged() {
    if (!mounted) return;
    if (AppConnectivity.instance.isOnline && _offlineBannerDismissed) {
      setState(() => _offlineBannerDismissed = false);
    }
  }

  @override
  void dispose() {
    AppConnectivity.instance.removeListener(_onConnectivityChanged);
    AuthRepository.instance.removeListener(_onAuthFormErrorChanged);
    _emailC.removeListener(_persistDraft);
    _fullNameC.removeListener(_persistDraft);
    _regC.removeListener(_persistDraft);
    _scrollC.dispose();
    _emailC.dispose();
    _fullNameC.dispose();
    _regC.dispose();
    _passwordC.dispose();
    _confirmC.dispose();
    super.dispose();
  }

  bool get _studentEmailOk =>
      StudentAuthEmail.validateFormat(_emailC.text) == null;

  bool get _staffEmailOk =>
      KiuStaffAuthEmail.validateFormat(_emailC.text) == null;

  bool get _staffRegOk =>
      KiuAdminRegistrationNumber.validateFormat(_regC.text) == null;

  /// @kiu.ac.ug + KIU####S — ambiguous until the user picks student or lecturer.
  bool get _staffShapedSignupCredentials {
    if (!_register) return false;
    final email = _emailC.text.trim();
    final reg = _regC.text.trim();
    if (email.isEmpty && reg.isEmpty) return false;
    final staffEmail = email.isNotEmpty && KiuStaffAuthEmail.isStaffMailbox(email);
    final staffReg = reg.isNotEmpty &&
        KiuAdminRegistrationNumber.validateFormat(reg) == null;
    return staffEmail || staffReg;
  }

  bool get _needsSignupRoleChoice => _staffShapedSignupCredentials;

  String? get _studentEmailError {
    if (!_register) return null;
    final raw = _emailC.text.trim();
    if (raw.isEmpty) return null;
    if (_needsSignupRoleChoice) {
      if (_signupAsStudent == true) {
        return StudentAuthEmail.validateFormat(_emailC.text);
      }
      if (_signupAsStudent == false) {
        return KiuStaffAuthEmail.validateFormat(_emailC.text);
      }
      // Wait for role choice before flagging email format.
      if (KiuStaffAuthEmail.isStaffMailbox(raw) ||
          StudentAuthEmail.isStudentMailbox(raw)) {
        return null;
      }
    }
    return StudentAuthEmail.validateFormat(_emailC.text);
  }

  bool get _loginIdOk {
    final raw = _emailC.text.trim();
    if (raw.isEmpty) return false;
    if (StaffAuthEmail.looksLikeStaffNumberOnly(raw)) {
      return StaffAuthEmail.normalizeStaffNumber(raw) != null;
    }
    if (KiuAdminRegistrationNumber.looksLikeRegistrationNumberOnly(raw)) {
      return true;
    }
    final resolved = StaffAuthEmail.resolveLoginEmail(raw) ?? '';
    if (!resolved.contains('@')) return false;
    if (StaffAuthEmail.syntheticEmailToStaffNumber(resolved) != null) {
      return true;
    }
    if (KiuStaffAuthEmail.skipsVerification(raw)) return true;
    if (KiuStaffAuthEmail.isStaffMailbox(raw)) {
      return KiuStaffAuthEmail.validateLoginFormat(raw) == null;
    }
    return StudentAuthEmail.validateLoginFormat(raw) == null;
  }

  bool get _regOk {
    if (_needsSignupRoleChoice) {
      if (_signupAsStudent == false) return _staffRegOk;
      if (_signupAsStudent == true) {
        return StudentRegistrationNumber.validateFormat(_regC.text) == null;
      }
      return false;
    }
    return StudentRegistrationNumber.validateFormat(_regC.text) == null;
  }

  bool get _fullNameOk => _fullNameC.text.trim().isNotEmpty;

  bool get _canSubmitLogin =>
      _loginIdOk && _passwordC.text.isNotEmpty && !_busy;

  bool get _emailOkForRegister {
    if (_needsSignupRoleChoice) {
      if (_signupAsStudent == true) return _studentEmailOk;
      if (_signupAsStudent == false) return _staffEmailOk;
      return false;
    }
    return _studentEmailOk;
  }

  bool get _canSubmitRegister =>
      _emailOkForRegister &&
      _fullNameOk &&
      _regOk &&
      (!_needsSignupRoleChoice || _signupAsStudent != null) &&
      _passwordC.text.length >= 6 &&
      _passwordC.text == _confirmC.text &&
      !_busy;

  void _clearAuthErrors() {
    AuthRepository.instance.clearAuthFormError();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    _persistDraft();
    if (_register && _needsSignupRoleChoice && _signupAsStudent == null) {
      AuthRepository.instance.presentAuthFormError(
        'These details look like a KIU staff account. '
        'Choose Student or Lecturer before creating the account.',
      );
      return;
    }
    if (_register &&
        _needsSignupRoleChoice &&
        _signupAsStudent == true &&
        (KiuStaffAuthEmail.isStaffMailbox(_emailC.text) &&
            KiuAdminRegistrationNumber.validateFormat(_regC.text) == null)) {
      AuthRepository.instance.presentAuthFormError(
        'A @kiu.ac.ug email with a KIU staff ID cannot be registered as a student. '
        'Choose Lecturer, or use your student email '
        '(${StudentAuthEmail.studentDomainsLabel()}) and registration number '
        '(${StudentRegistrationNumber.example}).',
      );
      return;
    }
    setState(() => _busy = true);
    AuthRepository.instance.clearAuthFormError();
    try {
      if (!mounted) return;
      await pushRootAppPage<AuthActionResult>(
        _LoginVerificationScreen(
          registering: _register,
          email: _emailC.text,
          fullName: _fullNameC.text.trim(),
          password: _passwordC.text,
          registrationNumber: _regC.text.trim(),
          signupRole: !_register
              ? null
              : (_needsSignupRoleChoice
                  ? (_signupAsStudent == true ? 'student' : 'lecturer')
                  : 'student'),
        ),
        fullscreenDialog: true,
      );
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
            child: SingleChildScrollView(
              controller: _scrollC,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListenableBuilder(
                    listenable: AppConnectivity.instance,
                    builder: (context, _) {
                      final offline =
                          AppConnectivity.instance.shouldShowOfflineBanner;
                      if (!offline || _offlineBannerDismissed) {
                        return const SizedBox.shrink();
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DismissibleErrorBanner(
                            message: AuthRepository.networkUnavailableMessage,
                            leadingIcon: Icons.wifi_off_rounded,
                            onDismiss: () =>
                                setState(() => _offlineBannerDismissed = true),
                          ),
                          const SizedBox(height: 16),
                        ],
                      );
                    },
                  ),
                  const Center(child: AppBrandLogo(size: 80, borderRadius: 20)),
                  const SizedBox(height: 16),
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
                      setState(() {
                        _register = s.first;
                        if (!_register) _signupAsStudent = null;
                      });
                      _persistDraft();
                    },
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _register
                        ? (_needsSignupRoleChoice
                            ? 'These details look like a KIU staff ID / @kiu.ac.ug email. Choose Student or Lecturer before the account is created.'
                            : 'Use your official KIU student email (${StudentAuthEmail.studentDomainsLabel()}), full name, registration number, and password.')
                        : 'Sign in with your ${StudentAuthEmail.studentDomainsLabel()} email, @kiu.ac.ug (lecturers), or KIU-#### (QA staff / lecturers).',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (_register && _needsSignupRoleChoice) ...[
                    const SizedBox(height: 16),
                    Text(
                      'I am a…',
                      textAlign: TextAlign.center,
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
                          label: Text('Student'),
                          icon: Icon(Icons.school_outlined),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text('Lecturer'),
                          icon: Icon(Icons.person_outline_rounded),
                        ),
                      ],
                      selected: _signupAsStudent == null
                          ? const <bool>{}
                          : {_signupAsStudent!},
                      onSelectionChanged: _busy
                          ? null
                          : (selection) {
                              setState(() {
                                _signupAsStudent = selection.isEmpty
                                    ? null
                                    : selection.first;
                              });
                              _clearAuthErrors();
                            },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _signupAsStudent == null
                          ? 'Required before create account — staff-shaped details are not assigned a role automatically.'
                          : _signupAsStudent == true
                              ? 'Students must use ${StudentAuthEmail.studentDomainsLabel()} and registration ${StudentRegistrationNumber.example}.'
                              : 'Lecturer accounts use @${KiuStaffAuthEmail.staffEmailDomain} and staff ID ${KiuAdminRegistrationNumber.example}.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                            height: 1.35,
                          ),
                    ),
                  ],
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
                            labelText: _register
                                ? (_needsSignupRoleChoice &&
                                        _signupAsStudent == false
                                    ? 'KIU staff email'
                                    : 'KIU school email')
                                : 'Email or staff ID',
                            hintText: _register
                                ? (_needsSignupRoleChoice &&
                                        _signupAsStudent == false
                                    ? KiuStaffAuthEmail.exampleEmail
                                    : StudentAuthEmail.exampleEmail)
                                : 'e.g. ${KiuStaffAuthEmail.exampleEmail} or KIU-0001',
                            errorText: _studentEmailError,
                            errorMaxLines: 4,
                          ),
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          textInputAction: TextInputAction.next,
                          onChanged: (_) {
                            _clearAuthErrors();
                            setState(() {
                              if (!_needsSignupRoleChoice) {
                                _signupAsStudent = null;
                              }
                            });
                          },
                        ),
                        if (_register &&
                            _studentEmailError == null &&
                            _emailC.text.trim().isEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Only your official KIU student mailbox (${StudentAuthEmail.studentDomainsLabel()}) can be used — not Gmail, Yahoo, or other personal email.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textSecondary,
                                  height: 1.35,
                                ),
                          ),
                        ],
                        if (_register && _studentEmailOk) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Format: firstname.lastname@${StudentAuthEmail.studentEmailDomain} or firstname.lastname@${StudentAuthEmail.studentEmailDomains.last}',
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
                            onChanged: (_) {
                            _clearAuthErrors();
                            setState(() {});
                          },
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
                            decoration: InputDecoration(
                              labelText: _needsSignupRoleChoice &&
                                      _signupAsStudent == false
                                  ? 'Staff ID'
                                  : 'Registration number',
                              hintText: _needsSignupRoleChoice &&
                                      _signupAsStudent == false
                                  ? KiuAdminRegistrationNumber.example
                                  : StudentRegistrationNumber.example,
                            ),
                            keyboardType: TextInputType.text,
                            autocorrect: false,
                            textCapitalization: TextCapitalization.characters,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) {
                              _clearAuthErrors();
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
                          onChanged: (_) {
                            _clearAuthErrors();
                            setState(() {});
                          },
                          onFieldSubmitted: (_) {
                            if (!_register &&
                                _canSubmitLogin &&
                                !_busy) {
                              _submit();
                            }
                          },
                        ),
                        if (!_register && kDebugMode) ...[
                          const SizedBox(height: 10),
                          Text(
                            'QA demo: ${StaffAuthEmail.normalizeStaffNumber('KIU-0001')} · '
                            '${StaffAuthEmail.defaultLecturerPassword}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textSecondary,
                                  height: 1.35,
                                ),
                          ),
                        ],
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
                          Center(
                            child: TextButton(
                              onPressed: _busy
                                  ? null
                                  : () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) =>
                                              const KiuStaffRegisterScreen(),
                                        ),
                                      );
                                    },
                              child: const Text(
                                'KIU staff? Register with @kiu.ac.ug',
                              ),
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
                            onChanged: (_) {
                            _clearAuthErrors();
                            setState(() {});
                          },
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Password must be at least 6 characters.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textSecondary,
                                ),
                          ),
                        ],
                        Builder(
                          key: _errorKey,
                          builder: (context) {
                            final formError = AuthRepository.instance
                                .authFormErrorMessage
                                ?.trim();
                            if (formError == null || formError.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const SizedBox(height: 8),
                                DismissibleErrorBanner(
                                  message: formError,
                                  onDismiss: _clearAuthErrors,
                                ),
                                const SizedBox(height: 16),
                              ],
                            );
                          },
                        ),
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
                  const SizedBox(height: 16),
                  const _DebugApiBaseLabel(),
                  const WebBuildLabel(),
                ],
              ),
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
    this.signupRole,
  });

  final bool registering;
  final String email;
  final String fullName;
  final String password;
  final String registrationNumber;
  /// `student`, `lecturer`, or null when signing in.
  final String? signupRole;

  @override
  State<_LoginVerificationScreen> createState() =>
      _LoginVerificationScreenState();
}

class _LoginVerificationScreenState extends State<_LoginVerificationScreen>
    with SingleTickerProviderStateMixin {
  int _stageIndex = 0;
  bool _done = false;
  String? _error;
  Timer? _stageTimer;
  late final AnimationController _progressPulse;

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
    _progressPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _startStageAnimation();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runAuthFlow());
  }

  @override
  void dispose() {
    _stageTimer?.cancel();
    _progressPulse.dispose();
    super.dispose();
  }

  void _startStageAnimation() {
    _stageTimer?.cancel();
    _stageIndex = 0;
    _stageTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (!mounted || _error != null || _done) return;
      if (_stageIndex < _stages.length - 1) {
        setState(() => _stageIndex++);
      }
    });
  }

  void _stopStageAnimation() {
    _stageTimer?.cancel();
    _stageTimer = null;
  }

  Future<void> _runAuthFlow() async {
    if (!mounted) return;
    final auth = AuthRepository.instance;
    final AuthActionResult result = widget.registering
        ? await auth.registerWithEmail(
            email: widget.email,
            fullName: widget.fullName,
            password: widget.password,
            registrationNumber: widget.registrationNumber,
            role: widget.signupRole ?? 'student',
          )
        : await auth.signInWithEmail(
            email: widget.email,
            password: widget.password,
          );
    if (!mounted) return;
    if (!result.ok) {
      _stopStageAnimation();
      final message = result.error?.trim();
      if (message != null && message.isNotEmpty) {
        AuthRepository.instance.presentAuthFormError(message);
      }
      if (widget.registering) {
        AuthRepository.instance.updateAuthFormDraft(
          email: widget.email,
          fullName: widget.fullName,
          registrationNumber: widget.registrationNumber,
          registering: true,
        );
      }
      if (!mounted) return;
      setState(() {
        _error = message;
        _done = false;
        _stageIndex = _stages.length - 1;
      });
      return;
    }
    _stopStageAnimation();
    setState(() => _done = true);
    if (!mounted) return;
    if (result.needsEmailVerification) {
      AuthRepository.instance.clearAuthFormDraft();
      if (!mounted) return;
      popToRootRoute();
      return;
    }
    Navigator.of(context).pop(result);
  }

  void _returnToSignIn() {
    Navigator.of(context).pop(
      AuthActionResult(error: _error ?? AuthRepository.instance.authFormErrorMessage),
    );
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
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppTheme.error.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: AppTheme.error.withValues(alpha: 0.4),
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.error_outline_rounded,
                                  color: AppTheme.error,
                                  size: 24,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _error!,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: AppTheme.textPrimary,
                                          fontWeight: FontWeight.w600,
                                          height: 1.45,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'This message stays on the sign-in form until you dismiss it or try again.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textSecondary,
                                  height: 1.4,
                                ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: _returnToSignIn,
                              child: const Text('Back to sign in'),
                            ),
                          ),
                        ] else ...[
                          FadeTransition(
                            opacity: Tween<double>(begin: 0.6, end: 1.0).animate(
                              CurvedAnimation(
                                parent: _progressPulse,
                                curve: Curves.easeInOut,
                              ),
                            ),
                            child: const Icon(
                              Icons.verified_user_outlined,
                              size: 48,
                              color: AppTheme.primary,
                            ),
                          ),
                          const SizedBox(height: 16),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              minHeight: 5,
                              value: _done
                                  ? 1
                                  : (_stageIndex + 1) / _stages.length,
                              backgroundColor: AppTheme.softGrey,
                              color: AppTheme.primary,
                            ),
                          ),
                          const SizedBox(height: 14),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 280),
                            child: Text(
                              _stages[_stageIndex],
                              key: ValueKey<int>(_stageIndex),
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    color: AppTheme.textSecondary,
                                    height: 1.4,
                                  ),
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

class _DebugApiBaseLabel extends StatelessWidget {
  const _DebugApiBaseLabel();

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'API: $uPanelApiBaseUrl',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppTheme.textTertiary,
              fontSize: 11,
            ),
      ),
    );
  }
}
