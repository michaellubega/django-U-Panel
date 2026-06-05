import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier, kIsWeb;

/// App-wide online/offline status derived from connectivity_plus.
///
/// This is a lightweight transport signal (network availability), not an
/// internet reachability guarantee.
class AppConnectivity extends ChangeNotifier {
  AppConnectivity._();
  static final AppConnectivity instance = AppConnectivity._();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _sub;

  bool _initialized = false;
  bool _isOnline = true;

  bool get isOnline => _isOnline;
  bool get initialized => _initialized;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final results = await _connectivity.checkConnectivity();
      _applyConnectivityResults(results);
    } catch (_) {}

    _sub = _connectivity.onConnectivityChanged.listen(_applyConnectivityResults);
  }

  void _setOnline(bool next) {
    if (_isOnline == next) return;
    _isOnline = next;
    notifyListeners();
  }

  /// On web, [checkConnectivity] can return an empty list → treat as online so
  /// features (e.g. sign-out gate) are not stuck "offline" in the browser.
  void _applyConnectivityResults(List<ConnectivityResult> results) {
    if (kIsWeb && results.isEmpty) {
      _setOnline(true);
      return;
    }
    _setOnline(results.any((c) => c != ConnectivityResult.none));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}

