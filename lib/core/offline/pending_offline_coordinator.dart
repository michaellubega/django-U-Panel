import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../auth/auth_repository.dart';
import '../connectivity/app_connectivity.dart';
import '../notifications/background_notification_worker.dart';
import '../../features/attendance/data/attendance_offline_sync.dart';

/// Keeps offline attendance queues uploading while the app process is alive
/// (including background / minimized) and maintains scheduled reminders.
class PendingOfflineCoordinator {
  PendingOfflineCoordinator._();

  static final PendingOfflineCoordinator instance =
      PendingOfflineCoordinator._();

  static const _tickInterval = Duration(minutes: 3);
  static const _syncDebounce = Duration(milliseconds: 300);
  static const _backgroundSyncTimeout = Duration(seconds: 50);
  static DateTime? _lastBackgroundSyncLogAt;

  Timer? _periodicTimer;
  Timer? _syncDebounceTimer;
  bool _running = false;
  bool _tickInFlight = false;
  bool _syncPendingAfterTick = false;

  void start() {
    if (_running) return;
    _running = true;
    AppConnectivity.instance.addListener(_onConnectivityChanged);
    unawaited(_tick(syncWhenOnline: true));
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(
      _tickInterval,
      (_) => unawaited(_tick(syncWhenOnline: true)),
    );
  }

  void stop() {
    AppConnectivity.instance.removeListener(_onConnectivityChanged);
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _running = false;
    _syncPendingAfterTick = false;
  }

  void onLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        requestSync(immediate: true);
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(_backgroundSync());
        break;
      case AppLifecycleState.inactive:
        // Web fires [inactive] during hot restart and focus churn — not true background.
        break;
    }
  }

  /// Fast upload for an in-progress student check-in (no full offline drain).
  void requestCheckInSync() {
    if (!_running) {
      start();
    }
    if (!AuthRepository.instance.isLoggedIn) return;
    if (!_canAttemptUploadSync) return;
    unawaited(AttendanceOfflineSync.drainCheckInUploadsOnly());
  }

  /// Debounced sync when pending work is enqueued; immediate when connectivity returns.
  void requestSync({bool immediate = false}) {
    if (!_running) {
      start();
    }
    if (immediate) {
      _syncDebounceTimer?.cancel();
      unawaited(_urgentSync());
      return;
    }
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = Timer(_syncDebounce, () {
      unawaited(_tick(syncWhenOnline: true));
    });
  }

  /// Upload queued check-ins when the device has network — do not require the
  /// optimistic [AppConnectivity.isOnline] flag (API probes can lag after 502s).
  static bool get _canAttemptUploadSync =>
      AppConnectivity.instance.hasNetworkInterface;

  void _onConnectivityChanged() {
    if (_canAttemptUploadSync) {
      requestSync(immediate: true);
    }
  }

  /// Best-effort upload when the app moves to background but is still running.
  Future<void> _backgroundSync() async {
    if (!AuthRepository.instance.isLoggedIn) return;
    if (!_canAttemptUploadSync) return;
    try {
      await AttendanceOfflineSync.drainUrgentUploadsOnly(
        timeBudget: _backgroundSyncTimeout,
      ).timeout(
        _backgroundSyncTimeout,
        onTimeout: () {
          _logBackgroundSyncTimeoutThrottled();
        },
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('PendingOfflineCoordinator: background sync failed: $e');
        debugPrint('$st');
      }
    }
  }

  void _logBackgroundSyncTimeoutThrottled() {
    if (!kDebugMode) return;
    final now = DateTime.now();
    final last = _lastBackgroundSyncLogAt;
    if (last != null && now.difference(last) < const Duration(minutes: 2)) {
      return;
    }
    _lastBackgroundSyncLogAt = now;
    debugPrint(
      'PendingOfflineCoordinator: background sync timed out — will retry later.',
    );
  }

  Future<void> _urgentSync() async {
    if (!_running || _tickInFlight) {
      _syncPendingAfterTick = true;
      return;
    }
    if (!AuthRepository.instance.isLoggedIn) return;
    if (!_canAttemptUploadSync) return;
    _tickInFlight = true;
    try {
      await AttendanceOfflineSync.drainCheckInUploadsOnly();
      unawaited(AttendanceOfflineSync.drainSessionValidationFirst());
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('PendingOfflineCoordinator: urgent sync failed: $e');
        debugPrint('$st');
      }
    } finally {
      _tickInFlight = false;
      if (_syncPendingAfterTick) {
        _syncPendingAfterTick = false;
        unawaited(_tick(syncWhenOnline: true));
      }
    }
  }

  Future<void> _tick({required bool syncWhenOnline}) async {
    if (!_running) return;
    if (_tickInFlight) {
      _syncPendingAfterTick = true;
      return;
    }
    if (!AuthRepository.instance.isLoggedIn) return;
    _tickInFlight = true;
    try {
      if (syncWhenOnline && _canAttemptUploadSync) {
        await AttendanceOfflineSync.drainSessionValidationFirst();
        if (AppConnectivity.instance.isOnline) {
          await AttendanceOfflineSync.drainAllInOrder();
        }
      }
      await BackgroundNotificationWorker.runAll();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('PendingOfflineCoordinator: tick failed: $e');
        debugPrint('$st');
      }
    } finally {
      _tickInFlight = false;
      if (_syncPendingAfterTick) {
        _syncPendingAfterTick = false;
        unawaited(_tick(syncWhenOnline: syncWhenOnline));
      }
    }
  }
}
