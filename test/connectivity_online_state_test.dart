import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/core/connectivity/connectivity_online_state.dart';

void main() {
  final now = DateTime.utc(2026, 3, 2, 12);

  test('stays online after one failed probe', () {
    expect(
      connectivityIsOnline(
        hasNetworkInterface: true,
        apiAttached: true,
        initialized: true,
        apiReachable: true,
        consecutiveProbeFailures: 1,
        lastSuccessfulProbe: now.subtract(const Duration(seconds: 1)),
        now: now,
      ),
      isTrue,
    );
  });

  test('goes offline after two failed probes even within grace window', () {
    expect(
      connectivityIsOnline(
        hasNetworkInterface: true,
        apiAttached: true,
        initialized: true,
        apiReachable: false,
        consecutiveProbeFailures: 2,
        lastSuccessfulProbe: now.subtract(const Duration(seconds: 2)),
        now: now,
      ),
      isFalse,
    );
  });

  test('offline when network interface is unavailable', () {
    expect(
      connectivityIsOnline(
        hasNetworkInterface: false,
        apiAttached: true,
        initialized: true,
        apiReachable: true,
        consecutiveProbeFailures: 0,
        now: now,
      ),
      isFalse,
    );
  });

  test('optimistic online before API probes attach', () {
    expect(
      connectivityIsOnline(
        hasNetworkInterface: true,
        apiAttached: false,
        initialized: true,
        apiReachable: false,
        consecutiveProbeFailures: 0,
        now: now,
      ),
      isTrue,
    );
  });
}
