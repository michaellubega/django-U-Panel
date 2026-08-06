import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_config.dart';
import 'api_exceptions.dart';

/// HTTP client for the Django REST API with token persistence.
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  static const _tokenKey = 'upanel_api_token_v1';

  String? _token;
  bool _loaded = false;

  /// True after [ensureLoaded] has read persisted token state.
  bool get isLoaded => _loaded;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey)?.trim();
    _loaded = true;
  }

  String? get token => _token;

  Future<void> setToken(String? value) async {
    _token = value?.trim();
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    if (_token == null || _token!.isEmpty) {
      await prefs.remove(_tokenKey);
    } else {
      await prefs.setString(_tokenKey, _token!);
    }
  }

  Future<void> clearToken() => setToken(null);

  Uri _uri(String path, [Map<String, String>? query]) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$uPanelApiBaseUrl$normalized').replace(queryParameters: query);
  }

  Map<String, String> _headers({bool jsonBody = false}) {
    final h = <String, String>{
      'Accept': 'application/json',
    };
    if (jsonBody) h['Content-Type'] = 'application/json';
    final t = _token;
    if (t != null && t.isNotEmpty) {
      h['Authorization'] = 'Token $t';
    }
    return h;
  }

  Future<Map<String, dynamic>?> getJson(
    String path, {
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final raw = await getDynamic(path, query: query, timeout: timeout);
    if (raw is Map<String, dynamic>) return raw;
    return null;
  }

  Future<dynamic> getDynamic(
    String path, {
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await ensureLoaded();
    final res = await http
        .get(_uri(path, query), headers: _headers())
        .timeout(timeout);
    return _decodeDynamicResponse(res);
  }

  Future<Map<String, dynamic>?> postJson(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await ensureLoaded();
    final res = await http
        .post(
          _uri(path),
          headers: _headers(jsonBody: true),
          body: jsonEncode(body),
        )
        .timeout(timeout);
    return _decodeJsonResponse(res);
  }

  Future<Map<String, dynamic>?> patchJson(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await ensureLoaded();
    final res = await http
        .patch(
          _uri(path),
          headers: _headers(jsonBody: true),
          body: jsonEncode(body),
        )
        .timeout(timeout);
    return _decodeJsonResponse(res);
  }

  Future<void> delete(String path) async {
    await ensureLoaded();
    final res = await http.delete(_uri(path), headers: _headers());
    if (res.statusCode >= 400) {
      throw ApiException('http-${res.statusCode}', res.body);
    }
  }

  /// Lightweight reachability probe (replaces Firestore meta/connectivity ping).
  Future<bool> ping({Duration timeout = const Duration(seconds: 6)}) async {
    try {
      final res = await http
          .get(_uri('/api/health/'), headers: _headers())
          .timeout(timeout);
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic>? _decodeJsonResponse(http.Response res) {
    final decoded = _decodeDynamicResponse(res);
    if (decoded is Map<String, dynamic>) return decoded;
    return null;
  }

  dynamic _decodeDynamicResponse(http.Response res) {
    if (res.statusCode == 204) return null;
    dynamic decoded;
    if (res.body.isNotEmpty) {
      decoded = jsonDecode(res.body);
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return decoded;
    final detail = decoded is Map
        ? decoded['detail']?.toString() ?? res.body
        : res.body;
    if (res.statusCode == 401) {
      throw ApiAuthException('invalid-credential', detail);
    }
    if (res.statusCode == 403) {
      throw ApiException('permission-denied', detail);
    }
    if (res.statusCode == 404) {
      throw ApiException('not-found', detail);
    }
    if (res.statusCode == 429) {
      throw ApiAuthException('too-many-requests', detail);
    }
    if (res.statusCode >= 500) {
      throw ApiException('unavailable', detail);
    }
    throw ApiException('http-${res.statusCode}', detail);
  }
}
