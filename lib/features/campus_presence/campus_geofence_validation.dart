import 'package:geolocator/geolocator.dart';

import 'models/campus_presence_models.dart';

/// Minimum check-in area radius (1.5 km). QA staff cannot go below this.
const double campusGeofenceMinRadiusMeters = 1500;

/// Maximum check-in area radius.
const double campusGeofenceMaxRadiusMeters = 5000;

/// Selectable radii for QA staff (all ≥ [campusGeofenceMinRadiusMeters]).
const List<double> campusGeofenceRadiusOptions = [
  1500,
  2000,
  2500,
  3000,
  4000,
  5000,
];

String formatCampusRadiusMeters(double meters) {
  if (meters >= 1000) {
    final km = meters / 1000;
    return km == km.roundToDouble()
        ? '${km.toStringAsFixed(0)} km'
        : '${km.toStringAsFixed(1)} km';
  }
  return '${meters.toInt()} m';
}

bool isCampusRadiusAllowed(double radiusMeters) =>
    radiusMeters >= campusGeofenceMinRadiusMeters &&
    radiusMeters <= campusGeofenceMaxRadiusMeters;

double clampCampusRadiusMeters(double radiusMeters) {
  if (radiusMeters < campusGeofenceMinRadiusMeters) {
    return campusGeofenceMinRadiusMeters;
  }
  if (radiusMeters > campusGeofenceMaxRadiusMeters) {
    return campusGeofenceMaxRadiusMeters;
  }
  return radiusMeters;
}

CampusGeofence? campusGeofenceFromFirestore(CampusGeofence? fromFirestore) {
  if (fromFirestore != null && fromFirestore.isConfigured) {
    return fromFirestore;
  }
  return null;
}

bool isPositionWithinCampus(CampusGeofence fence, double lat, double lng) {
  if (!fence.isConfigured || fence.radiusMeters <= 0) return false;
  final dist = Geolocator.distanceBetween(
    fence.latitude,
    fence.longitude,
    lat,
    lng,
  );
  return dist <= fence.radiusMeters;
}

String campusDistanceMessage(
  CampusGeofence fence,
  double lat,
  double lng,
) {
  final dist = Geolocator.distanceBetween(
    fence.latitude,
    fence.longitude,
    lat,
    lng,
  );
  return 'You are ${dist.toStringAsFixed(0)} m from the campus centre. '
      'You must be within ${formatCampusRadiusMeters(fence.radiusMeters)} '
      'of the centre to check in or out.';
}
