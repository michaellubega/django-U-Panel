class ApiException implements Exception {
  ApiException(this.code, [this.message]);

  final String code;
  final String? message;

  @override
  String toString() => message == null ? code : '$code: $message';
}

class ApiAuthException extends ApiException {
  ApiAuthException(super.code, [super.message]);
}
