import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/location/location_permission.dart';
import 'campus_geofence_validation.dart';
import 'campus_presence_check_progress.dart';
import 'data/campus_presence_repository.dart';
import 'models/campus_presence_models.dart';

/// Resolves GPS, verifies campus radius, and submits check-in / check-out.
abstract final class CampusPresenceCheckActions {
  CampusPresenceCheckActions._();

  static Future<bool> perform({
    required BuildContext context,
    required CampusPresenceKind kind,
  }) async {
    if (!AuthRepository.instance.isKiuAdmin) {
      _snack(context, 'Only KIU administrators can check in on campus.');
      return false;
    }

    if (!context.mounted) return false;

    final progress = await showCampusPresenceCheckProgress(
      context,
      kind: kind,
    );

    try {
      progress.setStep(CampusPresenceCheckStep.preparing);

      final status = await CampusPresenceRepository.instance
          .fetchTodayStatusForCurrentAdmin();

      if (kind == CampusPresenceKind.arrival && !status.canCheckIn) {
        progress.fail(
          status.failedToCheckOut
              ? 'You still need to check out from a previous day before checking in again.'
              : 'You are already checked in for today.',
        );
        await progress.close(delay: const Duration(milliseconds: 2200));
        return false;
      }
      if (kind == CampusPresenceKind.departure && !status.canCheckOut) {
        progress.fail(
          status.events.isEmpty
              ? 'Check in on campus first, then check out when you leave.'
              : 'You have already checked out for today.',
        );
        await progress.close(delay: const Duration(milliseconds: 2200));
        return false;
      }

      if (!await isDeviceLocationServiceEnabled()) {
        progress.fail('Turn on location services to record campus presence.');
        await progress.close(delay: const Duration(milliseconds: 2200));
        return false;
      }

      progress.setStep(CampusPresenceCheckStep.locating);
      final location = await acquireCurrentGpsPosition(
        timeLimit: const Duration(seconds: 30),
        highAccuracy: false,
      );

      if (location.position == null) {
        progress.fail(
          location.errorMessage ?? 'Could not get your location. Try again.',
        );
        await progress.close(delay: const Duration(milliseconds: 2400));
        return false;
      }

      final lat = location.position!.latitude;
      final lng = location.position!.longitude;

      progress.setStep(CampusPresenceCheckStep.loadingCampusArea);
      final fence =
          await CampusPresenceRepository.instance.fetchCampusGeofence();

      if (fence == null || !fence.isConfigured || fence.radiusMeters <= 0) {
        progress.fail(
          'The campus check-in area is not configured yet. Ask QA staff to '
          'set the campus centre before you can check in or out.',
        );
        await progress.close(delay: const Duration(milliseconds: 2800));
        return false;
      }

      progress.setStep(
        CampusPresenceCheckStep.verifyingRadius,
        detail:
            'Allowed radius: ${formatCampusRadiusMeters(fence.radiusMeters)} '
            'from the campus centre.',
      );

      if (!isPositionWithinCampus(fence, lat, lng)) {
        progress.fail(campusDistanceMessage(fence, lat, lng));
        await progress.close(delay: const Duration(milliseconds: 3200));
        return false;
      }

      progress.setStep(CampusPresenceCheckStep.saving);
      final result = await CampusPresenceRepository.instance.submitPresence(
        kind: kind,
        latitude: lat,
        longitude: lng,
      );

      switch (result.outcome) {
        case CampusPresenceSubmitOutcome.success:
          progress.succeed(
            kind == CampusPresenceKind.arrival
                ? 'You are checked in on campus.'
                : 'Your departure has been recorded.',
          );
          await progress.close(delay: const Duration(milliseconds: 900));
          if (context.mounted) {
            _snack(
              context,
              kind == CampusPresenceKind.arrival
                  ? 'Checked in on campus.'
                  : 'Checked out — departure recorded.',
            );
          }
          return true;
        case CampusPresenceSubmitOutcome.queuedOffline:
          progress.succeed(
            kind == CampusPresenceKind.arrival
                ? 'Checked in on this device. It will upload when you are online.'
                : 'Checked out on this device. It will upload when you are online.',
          );
          await progress.close(delay: const Duration(milliseconds: 900));
          if (context.mounted) {
            _snack(
              context,
              kind == CampusPresenceKind.arrival
                  ? 'Checked in on campus (saved on this device). '
                      'It will upload when you are online.'
                  : 'Checked out (saved on this device). '
                      'It will upload when you are online.',
            );
          }
          return true;
        case CampusPresenceSubmitOutcome.outsideCampus:
          progress.fail(
            result.message ??
                campusDistanceMessage(fence, lat, lng),
          );
          await progress.close(delay: const Duration(milliseconds: 3200));
          return false;
        default:
          progress.fail(
            result.message ?? 'Could not save campus presence.',
          );
          await progress.close(delay: const Duration(milliseconds: 2600));
          return false;
      }
    } catch (_) {
      progress.fail('Something went wrong. Try again.');
      await progress.close(delay: const Duration(milliseconds: 2200));
      return false;
    }
  }

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
