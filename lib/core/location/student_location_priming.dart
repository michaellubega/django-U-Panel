import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../auth/auth_repository.dart';
import '../auth/user_role.dart';
import '../connectivity/app_connectivity.dart';
import 'location_permission.dart';

/// Student GPS: prime on app open; check-in reuses a fix from the last 5 minutes.
class StudentLocationPriming extends ChangeNotifier {
  StudentLocationPriming._();
  static final StudentLocationPriming instance = StudentLocationPriming._();

  bool resolving = false;
  Position? lastPosition;
  String? errorMessage;
  bool locationServiceDisabled = false;
  bool permissionBlocked = false;

  Future<GpsAcquireResult>? _inFlight;

  static bool shouldRunForCurrentUser() {
    final auth = AuthRepository.instance;
    return auth.isLoggedIn &&
        auth.roleCheckDone &&
        auth.resolvedRole == UserRole.student;
  }

  void _applyResult(GpsAcquireResult result, {required bool resolving}) {
    this.resolving = resolving;
    lastPosition = result.position;
    errorMessage = result.errorMessage;
    locationServiceDisabled = result.locationServiceDisabled;
    permissionBlocked = result.permissionBlocked;
    notifyListeners();
  }

  /// App open / resume — prompt for permission and start resolving GPS.
  Future<void> primeOnAppOpen() async {
    if (!shouldRunForCurrentUser()) return;
    await acquireFreshForCheckIn();
  }

  /// Check-in — permission + GPS; reuses last-known fix when ≤ 5 minutes old.
  Future<GpsAcquireResult> acquireFreshForCheckIn() async {
    if (_inFlight != null) {
      return _inFlight!;
    }

    final run = _resolveFresh();
    _inFlight = run;
    try {
      return await run;
    } finally {
      if (identical(_inFlight, run)) {
        _inFlight = null;
      }
    }
  }

  Future<GpsAcquireResult> _resolveFresh() async {
    if (!kIsWeb && !await isDeviceLocationServiceEnabled()) {
      const result = GpsAcquireResult(
        locationServiceDisabled: true,
        errorMessage:
            'Location is turned off. Turn on GPS, then tap Get current location.',
      );
      _applyResult(result, resolving: false);
      return result;
    }

    _applyResult(
      const GpsAcquireResult(),
      resolving: true,
    );

    final isOnline = AppConnectivity.instance.isOnline;
    final result = await acquireCurrentGpsPosition(
      timeLimit: isOnline
          ? const Duration(seconds: 12)
          : const Duration(seconds: 18),
      forceFresh: false,
    );
    _applyResult(result, resolving: false);
    return result;
  }
}
