import 'campus_presence_grouping.dart';

import 'models/campus_presence_models.dart';

/// Campus presence schedule rules for QA / admin staff.
abstract final class CampusPresencePolicy {
  /// On time if check-in is at or before this time.
  static const int checkInOnTimeLatestHour = 8;
  static const int checkInOnTimeLatestMinute = 30;

  /// Check-out before this is "left early".
  static const int earlyCheckoutBeforeHour = 17;
  static const int earlyCheckoutBeforeMinute = 0;

  /// Check-out after this is "overwork".
  static const int overworkAfterHour = 17;
  static const int overworkAfterMinute = 30;

  static int _minutesOfDay(DateTime t) => t.hour * 60 + t.minute;

  static int get _checkInOnTimeLatestMinutes =>
      checkInOnTimeLatestHour * 60 + checkInOnTimeLatestMinute;

  static int get _earlyCheckoutBeforeMinutes =>
      earlyCheckoutBeforeHour * 60 + earlyCheckoutBeforeMinute;

  static int get _overworkAfterMinutes =>
      overworkAfterHour * 60 + overworkAfterMinute;

  static bool isLateArrival(DateTime arrival) =>
      _minutesOfDay(arrival) > _checkInOnTimeLatestMinutes;

  static bool isEarlyDeparture(DateTime departure) =>
      _minutesOfDay(departure) < _earlyCheckoutBeforeMinutes;

  static bool isOverwork(DateTime departure) =>
      _minutesOfDay(departure) > _overworkAfterMinutes;

  /// Minutes after 8:30 AM check-in deadline (null if on time).
  static Duration? latenessAfterThreshold(DateTime arrival) {
    final minutes = _minutesOfDay(arrival) - _checkInOnTimeLatestMinutes;
    if (minutes <= 0) return null;
    return Duration(minutes: minutes);
  }

  /// Minutes before 5:00 PM when leaving early (null if not early).
  static Duration? earlinessBeforeThreshold(DateTime departure) {
    final minutes = _earlyCheckoutBeforeMinutes - _minutesOfDay(departure);
    if (minutes <= 0) return null;
    return Duration(minutes: minutes);
  }

  /// Minutes after 5:30 PM when overworking (null if not overwork).
  static Duration? overworkAfterThreshold(DateTime departure) {
    final minutes = _minutesOfDay(departure) - _overworkAfterMinutes;
    if (minutes <= 0) return null;
    return Duration(minutes: minutes);
  }

  static String lateTagLabel(DateTime arrival) {
    final by = latenessAfterThreshold(arrival);
    if (by == null) return 'Late';
    return 'Late ${formatDuration(by)}';
  }

  static String earlyDepartureTagLabel(DateTime departure) {
    final by = earlinessBeforeThreshold(departure);
    if (by == null) return 'Left early';
    return 'Left early ${formatDuration(by)}';
  }

  static String overworkTagLabel(DateTime departure) {
    final by = overworkAfterThreshold(departure);
    if (by == null) return 'Overwork';
    return 'Overwork ${formatDuration(by)}';
  }

  static DateTime? dateFromLocalDateKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  /// Last valid checkout instant on [localDateKey] (23:59:59.999 local).
  static DateTime endOfLocalDateKey(String localDateKey) {
    final start = dateFromLocalDateKey(localDateKey);
    if (start == null) return DateTime.now();
    return DateTime(
      start.year,
      start.month,
      start.day,
      23,
      59,
      59,
      999,
    );
  }

  /// True when [now] is on a calendar day after [localDateKey].
  static bool isCheckoutWindowClosed(String localDateKey, DateTime now) {
    return localDateKeyFor(now).compareTo(localDateKey) > 0;
  }

  /// Checkout must occur on the same local date as check-in.
  static bool isCheckoutOnSameDayAsCheckIn({
    required String checkInDateKey,
    required DateTime checkoutTime,
  }) {
    return localDateKeyFor(checkoutTime) == checkInDateKey;
  }

  static CampusDayPresenceFlags evaluate(
    StaffDayPresenceRow row, {
    DateTime? asOf,
  }) {
    final now = asOf ?? DateTime.now();
    final arrival = row.arrival;
    final departure = row.departure;
    final closed = isCheckoutWindowClosed(row.localDateKey, now);

    final failedCheckout = arrival != null && departure == null && closed;

    var lateArrival = false;
    if (arrival != null) {
      lateArrival = isLateArrival(arrival.capturedAt);
    }

    var earlyDeparture = false;
    var overwork = false;
    if (departure != null) {
      earlyDeparture = isEarlyDeparture(departure.capturedAt);
      overwork = isOverwork(departure.capturedAt);
    }

    final Duration? hours;
    if (arrival == null) {
      hours = null;
    } else if (departure != null) {
      hours = departure.capturedAt.difference(arrival.capturedAt);
    } else if (failedCheckout) {
      hours = endOfLocalDateKey(row.localDateKey)
          .difference(arrival.capturedAt);
    } else {
      hours = now.difference(arrival.capturedAt);
    }

    final labels = <String>[];
    if (lateArrival && arrival != null) {
      labels.add(lateTagLabel(arrival.capturedAt));
    }
    if (earlyDeparture && departure != null) {
      labels.add(earlyDepartureTagLabel(departure.capturedAt));
    }
    if (overwork && departure != null) {
      labels.add(overworkTagLabel(departure.capturedAt));
    }
    if (failedCheckout) labels.add('Failed to check out');
    if (arrival != null && departure == null && !closed) {
      labels.add('On campus');
    }

    return CampusDayPresenceFlags(
      lateArrival: lateArrival,
      earlyDeparture: earlyDeparture,
      overwork: overwork,
      failedCheckout: failedCheckout,
      hoursOnCampus: hours,
      statusLabels: labels,
    );
  }

  static String formatDuration(Duration d) {
    if (d.isNegative) return '0m';
    final totalMinutes = d.inMinutes;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours <= 0) return '${minutes}m';
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }
}

/// Derived attendance flags for one staff day row.
class CampusDayPresenceFlags {
  const CampusDayPresenceFlags({
    required this.lateArrival,
    required this.earlyDeparture,
    required this.overwork,
    required this.failedCheckout,
    required this.hoursOnCampus,
    required this.statusLabels,
  });

  final bool lateArrival;
  final bool earlyDeparture;
  final bool overwork;
  final bool failedCheckout;
  final Duration? hoursOnCampus;
  final List<String> statusLabels;

  String get hoursLabel => hoursOnCampus == null
      ? '—'
      : CampusPresencePolicy.formatDuration(hoursOnCampus!);

  /// Status tag for a late arrival, if any.
  String? get arrivalStatusNote {
    for (final label in statusLabels) {
      if (label.startsWith('Late')) return label;
    }
    return null;
  }

  /// All departure-related status tags (early leave, overwork, failed checkout).
  List<String> get departureStatusNotes => [
        for (final label in statusLabels)
          if (label.startsWith('Left early') ||
              label.startsWith('Overwork') ||
              label.startsWith('Failed to check out'))
            label,
      ];

  String? get departureStatusNote {
    final notes = departureStatusNotes;
    if (notes.isEmpty) return null;
    return notes.join(' · ');
  }
}

extension StaffDayPresenceRowPolicy on StaffDayPresenceRow {
  CampusDayPresenceFlags flags({DateTime? asOf}) =>
      CampusPresencePolicy.evaluate(this, asOf: asOf);
}

extension StaffPresencePeriodSummaryPolicy on StaffPresencePeriodSummary {
  Duration get totalHoursOnCampus {
    var total = Duration.zero;
    for (final row in dayRows) {
      final h = row.flags().hoursOnCampus;
      if (h != null) total += h;
    }
    return total;
  }

  String get totalHoursLabel =>
      CampusPresencePolicy.formatDuration(totalHoursOnCampus);

  /// Days with a late arrival in this period.
  int get lateArrivalCount =>
      dayRows.where((row) => row.flags().lateArrival).length;

  /// Days with an early departure in this period.
  int get earlyLeaveCount =>
      dayRows.where((row) => row.flags().earlyDeparture).length;

  /// Sum of minutes worked past 5:30 PM on days with overwork.
  Duration get totalOverworkDuration {
    var total = Duration.zero;
    for (final row in dayRows) {
      final departure = row.departure?.capturedAt;
      if (departure == null) continue;
      final over = CampusPresencePolicy.overworkAfterThreshold(departure);
      if (over != null) total += over;
    }
    return total;
  }

  String get totalOverworkLabel =>
      CampusPresencePolicy.formatDuration(totalOverworkDuration);

  String get campusVisitLabel =>
      'Campus visits: $checkInCount';

  String get lateArrivalCountLabel =>
      'Late arrivals: $lateArrivalCount';

  String get earlyLeaveCountLabel =>
      'Early leaves: $earlyLeaveCount';

  String get totalOverworkSummaryLabel =>
      'Total overwork: $totalOverworkLabel';

  /// One-line period totals for week / month list rows.
  String get periodStatsLine => [
        campusVisitLabel,
        lateArrivalCountLabel,
        earlyLeaveCountLabel,
        totalOverworkSummaryLabel,
      ].join(' · ');
}
