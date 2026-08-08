import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'api_exceptions.dart';

/// Authenticated user (replaces Firebase [User]).
class ApiUser {
  ApiUser({
    required this.uid,
    required this.email,
    this.emailVerified = false,
    this.displayName,
    this.raw,
  });

  final String uid;
  final String email;
  bool emailVerified;
  String? displayName;
  final Map<String, dynamic>? raw;

  Future<void> reload() async {
    final json = await ApiClient.instance.getJson('/api/auth/me/');
    if (json == null) return;
    emailVerified = json['email_verified'] == true;
    displayName = (json['full_name'] as String?)?.trim();
  }

  Future<String?> getIdToken(bool forceRefresh) async {
    await ApiClient.instance.ensureLoaded();
    return ApiClient.instance.token;
  }

  Future<void> updateDisplayName(String? name) async {
    displayName = name?.trim();
    await ApiClient.instance.patchJson('/api/auth/me/', {
      'full_name': displayName ?? '',
    });
  }

  Future<void> sendEmailVerification() async {
    await ApiClient.instance.postJson('/api/auth/request-verification/', {});
  }

  Future<void> delete() async {
    try {
      await ApiClient.instance.delete('/api/auth/me/');
    } catch (_) {}
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await ApiClient.instance.postJson('/api/auth/change-password/', {
      'current_password': currentPassword,
      'new_password': newPassword,
    });
  }
}

class ApiUserCredential {
  ApiUserCredential({this.user});
  final ApiUser? user;
}

/// Token-based auth against the Django REST API (replaces [FirebaseAuth]).
class ApiAuth {
  ApiAuth._();
  static final ApiAuth instance = ApiAuth._();

  final _controller = StreamController<ApiUser?>.broadcast();
  ApiUser? _currentUser;

  ApiUser? get currentUser => _currentUser;

  Stream<ApiUser?> authStateChanges() => _controller.stream;

  Future<void> _emit(ApiUser? user) async {
    _currentUser = user;
    if (!_controller.isClosed) {
      _controller.add(user);
    }
  }

  Future<void> restoreSession() async {
    await ApiClient.instance.ensureLoaded();
    if (ApiClient.instance.token == null) {
      await _emit(null);
      return;
    }
    try {
      final json = await ApiClient.instance.getJson('/api/auth/me/');
      if (json == null) {
        await ApiClient.instance.clearToken();
        await _emit(null);
        return;
      }
      final id = json['id']?.toString() ?? '';
      await _emit(
        ApiUser(
          uid: id,
          email: (json['email'] as String?)?.trim() ?? '',
          emailVerified: json['email_verified'] == true,
          displayName: (json['full_name'] as String?)?.trim(),
          raw: json,
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('ApiAuth.restoreSession: $e');
      await ApiClient.instance.clearToken();
      await _emit(null);
    }
  }

  Future<ApiUserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    final json = await ApiClient.instance.postJson('/api/auth/login/', {
      'email': email.trim().toLowerCase(),
      'password': password,
    });
    if (json == null) {
      throw ApiAuthException('invalid-credential', 'Empty login response.');
    }
    final token = json['token']?.toString();
    if (token == null || token.isEmpty) {
      throw ApiAuthException('invalid-credential', 'Missing auth token.');
    }
    await ApiClient.instance.setToken(token);
    final userJson = json['user'] as Map<String, dynamic>? ?? {};
    final user = ApiUser(
      uid: userJson['id']?.toString() ?? '',
      email: (userJson['email'] as String?)?.trim() ?? email.trim().toLowerCase(),
      emailVerified: userJson['email_verified'] == true,
      displayName: (userJson['full_name'] as String?)?.trim(),
      raw: userJson,
    );
    await _emit(user);
    return ApiUserCredential(user: user);
  }

  Future<ApiUserCredential> createUserWithEmailAndPassword({
    required String email,
    required String password,
    String? fullName,
    String? registrationNumber,
  }) async {
    final body = <String, dynamic>{
      'email': email.trim().toLowerCase(),
      'password': password,
    };
    final name = fullName?.trim();
    if (name != null && name.isNotEmpty) {
      body['full_name'] = name;
    }
    final reg = registrationNumber?.trim();
    if (reg != null && reg.isNotEmpty) {
      body['registration_number'] = reg;
    }
    final json = await ApiClient.instance.postJson('/api/auth/register/', body);
    if (json == null) {
      throw ApiAuthException('unknown', 'Empty registration response.');
    }
    final token = json['token']?.toString();
    if (token == null || token.isEmpty) {
      throw ApiAuthException(
        'unknown',
        'Registration succeeded but no auth token was returned.',
      );
    }
    await ApiClient.instance.setToken(token);
    final userJson = json['user'] as Map<String, dynamic>? ?? {};
    final user = ApiUser(
      uid: userJson['id']?.toString() ?? '',
      email: (userJson['email'] as String?)?.trim() ?? email.trim().toLowerCase(),
      emailVerified: userJson['email_verified'] == true,
      displayName: (userJson['full_name'] as String?)?.trim(),
      raw: userJson,
    );
    await _emit(user);
    return ApiUserCredential(user: user);
  }

  Future<void> signOut() async {
    try {
      await ApiClient.instance.postJson('/api/auth/logout/', {});
    } catch (_) {}
    await ApiClient.instance.clearToken();
    await _emit(null);
  }

  Future<void> sendPasswordResetEmail({required String email}) async {
    await ApiClient.instance.postJson('/api/auth/password-reset/', {
      'email': email.trim().toLowerCase(),
    });
  }
}

/// Secondary auth instance for staff registration flows (no separate Firebase app).
ApiAuth registrationAuth() => ApiAuth.instance;
