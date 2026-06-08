import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, defaultTargetPlatform, kDebugMode, kIsWeb, TargetPlatform;

import '../firebase/firestore_collections.dart';
import '../firebase/u_panel_firestore.dart';

/// App-wide online/offline status.
///
/// Uses [connectivity_plus] as a transport hint and confirms reachability with
/// a lightweight Firestore server read on [FirestoreCollections.meta]/connectivity.
class AppConnectivity extends ChangeNotifier {
  AppConnectivity._();
  static final AppConnectivity instance = AppConnectivity._();

  static const Duration _probeTimeout = Duration(seconds: 6);
  static const Duration _probeInterval = Duration(seconds: 30);
  static const Duration _reachabilityGrace = Duration(seconds: 25);
  static const Duration _minProbeGap = Duration(seconds: 2);
  static const int _failuresBeforeOffline = 2;

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _periodicProbe;

  bool _initialized = false;
  bool _firebaseAttached = false;
  bool _hasNetworkInterface = true;
  bool _firestoreReachable = false;
  bool _probeInFlight = false;
  int _consecutiveProbeFailures = 0;
  DateTime? _lastSuccessfulProbe;
  DateTime? _lastProbeAttempt;

  /// Device reports Wi‑Fi / mobile data / ethernet (not airplane mode).
  bool get hasNetworkInterface => _hasNetworkInterface;

  /// Last Firestore server probe succeeded (ignoring grace window).
  bool get firestoreReachable => _firestoreReachable;

  /// True when the device has a network interface and Firestore was reachable
  /// recently, or reachability has not been disproved yet.
  bool get isOnline {
    if (!_hasNetworkInterface) return false;
    if (!_firebaseAttached || !_initialized) return true;
    if (_firestoreReachable) return true;
    if (_recentlyReachable) return true;
    if (_consecutiveProbeFailures < _failuresBeforeOffline) return true;
    return false;
  }

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
    _maybeAttachFirebase();
    notifyListeners();
  }

  /// Confirms Firestore reachability before a critical online operation (check-in).
  Future<bool> ensureReachable({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_hasNetworkInterface) {
      _recordProbeFailure();
      return false;
    }
    if (!_initialized) await initialize();
    _maybeAttachFirebase();
    if (!_firebaseAttached) return true;

    if (_firestoreReachable || _recentlyReachable) return true;

    final reachable = await _firestoreServerReachable(timeout: timeout);
    _applyProbeResult(reachable);
    if (reachable) return true;
    return _consecutiveProbeFailures < _failuresBeforeOffline;
  }

  /// Re-run the Firestore server probe (e.g. on app resume).
  Future<void> probeNow({bool force = false}) async {
    if (!_initialized) await initialize();
    _maybeAttachFirebase();
    await _runFirestoreProbe(force: force);
  }

  void _maybeAttachFirebase() {
    if (_firebaseAttached || Firebase.apps.isEmpty) return;
    _firebaseAttached = true;
    // Web login path should not block on Firestore probes — defer until needed.
    if (kIsWeb) return;
    unawaited(_runFirestoreProbe(force: true));
    _periodicProbe?.cancel();
    _periodicProbe = Timer.periodic(_probeInterval, (_) {
      unawaited(_runFirestoreProbe());
    });
  }

  DocumentReference<Map<String, dynamic>> _probeDocumentRef() {
    return uPanelFirestore()
        .collection(FirestoreCollections.meta)
        .doc(FirestoreCollections.connectivityPingDocId);
  }

  Future<void> _runFirestoreProbe({bool force = false}) async {
    if (!_firebaseAttached || _probeInFlight) return;
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
      final reachable = await _firestoreServerReachable();
      _applyProbeResult(reachable);
    } finally {
      _probeInFlight = false;
    }
  }

  Future<bool> _firestoreServerReachable({
    Duration timeout = _probeTimeout,
  }) async {
    if (Firebase.apps.isEmpty) return _hasNetworkInterface;
    try {
      await _probeDocumentRef()
          .get(const GetOptions(source: Source.server))
          .timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } on FirebaseException catch (e) {
      if (_isFirestoreOfflineError(e)) return false;
      if (_isFirestoreReachableError(e)) return true;
      return false;
    } on SocketException {
      return false;
    } catch (_) {
      return false;
    }
  }

  bool _isFirestoreOfflineError(Object error) {
    if (error is FirebaseException) {
      return error.code == 'unavailable';
    }
    return error is TimeoutException || error is SocketException;
  }

  /// Server responded (rules/doc issues still mean the network path works).
  bool _isFirestoreReachableError(Object error) {
    if (error is FirebaseException) {
      return error.code == 'permission-denied' ||
          error.code == 'not-found' ||
          error.code == 'failed-precondition';
    }
    return false;
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
      _setFirestoreReachable(false, notify: false);
      if (notify && isOnline != onlineBefore) notifyListeners();
      return;
    }

    if (!hadNetwork && _hasNetworkInterface) {
      _consecutiveProbeFailures = 0;
      unawaited(_runFirestoreProbe(force: true));
    } else if (notify && isOnline != onlineBefore) {
      notifyListeners();
    }
  }

  void _applyProbeResult(bool reachable) {
    if (reachable) {
      _consecutiveProbeFailures = 0;
      _setFirestoreReachable(true);
      return;
    }
    _recordProbeFailure();
  }

  void _recordProbeFailure() {
    _consecutiveProbeFailures =
        (_consecutiveProbeFailures + 1).clamp(0, _failuresBeforeOffline + 2);
    if (_consecutiveProbeFailures >= _failuresBeforeOffline) {
      _setFirestoreReachable(false);
    } else if (kDebugMode) {
      debugPrint(
        'AppConnectivity: probe failed ($_consecutiveProbeFailures/$_failuresBeforeOffline) — still treating as online.',
      );
    }
  }

  void _setFirestoreReachable(bool next, {bool notify = true}) {
    if (next) {
      _lastSuccessfulProbe = DateTime.now();
      _consecutiveProbeFailures = 0;
    }
    final onlineBefore = isOnline;
    if (_firestoreReachable == next) {
      if (next && notify && isOnline != onlineBefore) notifyListeners();
      return;
    }
    _firestoreReachable = next;
    if (kDebugMode) {
      debugPrint(
        'AppConnectivity: firestoreReachable=$next isOnline=$isOnline failures=$_consecutiveProbeFailures',
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
