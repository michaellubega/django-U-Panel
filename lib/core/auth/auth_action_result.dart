/// Outcome of sign-in or student registration.
class AuthActionResult {
  const AuthActionResult({
    this.error,
    this.needsEmailVerification = false,
  });

  final String? error;
  final bool needsEmailVerification;

  bool get ok => error == null;
}
