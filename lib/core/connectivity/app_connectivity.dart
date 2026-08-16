import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, defaultTargetPlatform, kDebugMode, kIsWeb, TargetPlatform;

import '../api/api_client.dart';
import '../api/api_config.dart';
import 'connectivity_online_state.dart';

/// App-wide online/offline status.
///
/// Uses [connectivity_plus] as a transport hint and confirms reachability with
/// [ApiClient.instance.ping].
class AppConnectivity extends ChangeNotifier {
  AppConnectivity._();
  static final AppConnectivity instance = AppConnectivity._();

  static const Duration _probeTimeout = Duration(seconds: 4);
  static const Duration _probeInterval = Duration(seconds: 5);
  static const Duration _reachabilityGrace = Duration(seconds: 8);
  static const Duration _minProbeGap = Duration(seconds: 2);
  static const int _failuresBeforeOffline = 2;

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _periodicProbe;

  bool _initialized = false;
  bool _apiAttached = false;
  bool _hasNetworkInterface = true;
  bool _apiReachable = false;
  bool _probeInFlight = false;
  int _consecutiveProbeFailures = 0;
  DateTime? _lastSuccessfulProbe;
  DateTime? _lastProbeAttempt;

  /// Device reports Wi‑Fi / mobile data / ethernet (not airplane mode).
  bool get hasNetworkInterface => _hasNetworkInterface;

  /// Last API server probe succeeded (ignoring grace window).
  bool get apiReachable => _apiReachable;

  /// Back-compat alias for callers still named after Firestore.
  bool get firestoreReachable => _apiReachable;

  /// True when the device has a network interface and the API was reachable
  /// recently, or reachability has not been disproved yet.
  bool get isOnline => connectivityIsOnline(
        hasNetworkInterface: _hasNetworkInterface,
        apiAttached: _apiAttached,
        initialized: _initialized,
        apiReachable: _apiReachable,
        consecutiveProbeFailures: _consecutiveProbeFailures,
        lastSuccessfulProbe: _lastSuccessfulProbe,
        reachabilityGrace: _reachabilityGrace,
        failuresBeforeOffline: _failuresBeforeOffline,
      );

  /// Two failed API probes in a row — used by the offline banner.
  bool get shouldShowOfflineBanner =>
      initialized && _apiAttached && !isOnline;

  bool get _recentlyReachable {
    final at = _lastSuccessfulProbe;
    if (at == null) return false;
    return DateTime.now().difference(at) < _reachabilityGrace;
  }

  bool get initialized => _initialized;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final results = await _connectivity.checkConnectivity();
      _applyConnectivityResults(results, notify: false);
    } catch (_) {}

    _connectivitySub =
        _connectivity.onConnectivityChanged.listen(_applyConnectivityResults);
    _maybeAttachApi();
    notifyListeners();
  }

  /// Confirms API reachability before a critical online operation (check-in).
  Future<bool> ensureReachable({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_hasNetworkInterface) {
      _recordProbeFailure();
      return false;
    }
    if (!_initialized) await initialize();
    _maybeAttachApi();
    if (!_apiAttached) return true;

    if (_apiReachable || _recentlyReachable) return true;

    final reachable = await _apiServerReachable(timeout: timeout);
    _applyProbeResult(reachable);
    if (reachable) return true;
    return _consecutiveProbeFailures < _failuresBeforeOffline;
  }

  /// Re-run the API server probe (e.g. on app resume).
  Future<void> probeNow({bool force = false}) async {
    if (!_initialized) await initialize();
    _maybeAttachApi();
    await _runApiProbe(force: force);
  }

  void _maybeAttachApi() {
    if (_apiAttached || !isApiConfigured) return;
    _apiAttached = true;
    unawaited(_runApiProbe(force: true));
    _periodicProbe?.cancel();
    _periodicProbe = Timer.periodic(_probeInterval, (_) {
      unawaited(_runApiProbe());
    });
  }

  Future<void> _runApiProbe({bool force = false}) async {
    if (!_apiAttached || _probeInFlight) return;
    if (!_hasNetworkInterface && !_assumeOnlineWhenConnectivityUnknown) {
      _recordProbeFailure();
      return;
    }

    final now = DateTime.now();
    if (!force &&
        _lastProbeAttempt != null &&
        now.difference(_lastProbeAttempt!) < _minProbeGap) {
      return;
    }

    _probeInFlight = true;
    _lastProbeAttempt = now;
    try {
      final reachable = await _apiServerReachable();
      _applyProbeResult(reachable);
    } finally {
      _probeInFlight = false;
    }
  }

  Future<bool> _apiServerReachable({
    Duration timeout = _probeTimeout,
  }) async {
    if (!isApiConfigured) return _hasNetworkInterface;
    try {
      return await ApiClient.instance.ping(timeout: timeout);
    } on TimeoutException {
      return false;
    } on SocketException {
      return false;
    } catch (_) {
      return false;
    }
  }

  void _applyConnectivityResults(
    List<ConnectivityResult> results, {
    bool notify = true,
  }) {
    final onlineBefore = isOnline;
    final hadNetwork = _hasNetworkInterface;
    if (results.isEmpty && _assumeOnlineWhenConnectivityUnknown) {
      _hasNetworkInterface = true;
    } else {
      _hasNetworkInterface =
          results.any((c) => c != ConnectivityResult.none);
    }

    if (!_hasNetworkInterface) {
      _consecutiveProbeFailures = _failuresBeforeOffline;
      _setApiReachable(false, notify: false);
      if (notify && isOnline != onlineBefore) notifyListeners();
      return;
    }

    if (!hadNetwork && _hasNetworkInterface) {
      _consecutiveProbeFailures = 0;
      unawaited(_runApiProbe(force: true));
    } else if (notify && isOnline != onlineBefore) {
      notifyListeners();
    }
  }

  void _applyProbeResult(bool reachable) {
    if (reachable) {
      _consecutiveProbeFailures = 0;
      _setApiReachable(true);
      return;
    }
    _recordProbeFailure();
  }

  void _recordProbeFailure() {
    final onlineBefore = isOnline;
    _consecutiveProbeFailures =
        (_consecutiveProbeFailures + 1).clamp(0, _failuresBeforeOffline + 2);
    if (_consecutiveProbeFailures >= _failuresBeforeOffline) {
      _lastSuccessfulProbe = null;
      _apiReachable = false;
    }
    if (kDebugMode &&
        _consecutiveProbeFailures < _failuresBeforeOffline) {
      debugPrint(
        'AppConnectivity: probe failed ($_consecutiveProbeFailures/$_failuresBeforeOffline) — still treating as online.',
      );
    }
    if (isOnline != onlineBefore) {
      if (kDebugMode) {
        debugPrint(
          'AppConnectivity: isOnline=$isOnline failures=$_consecutiveProbeFailures',
        );
      }
      notifyListeners();
    }
  }

  void _setApiReachable(bool next, {bool notify = true}) {
    if (next) {
      _lastSuccessfulProbe = DateTime.now();
      _consecutiveProbeFailures = 0;
    }
    final onlineBefore = isOnline;
    if (_apiReachable == next) {
      if (next && notify && isOnline != onlineBefore) notifyListeners();
      return;
    }
    _apiReachable = next;
    if (kDebugMode) {
      debugPrint(
        'AppConnectivity: apiReachable=$next isOnline=$isOnline failures=$_consecutiveProbeFailures',
      );
    }
    if (notify && isOnline != onlineBefore) notifyListeners();
  }

  static bool get _assumeOnlineWhenConnectivityUnknown {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _periodicProbe?.cancel();
    _periodicProbe = null;
    super.dispose();
  }
}
