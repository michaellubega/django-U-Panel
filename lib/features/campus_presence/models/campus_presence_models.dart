import 'package:cloud_firestore/cloud_firestore.dart';

/// Arrival at campus or departure when leaving.
enum CampusPresenceKind {
  arrival,
  departure,
}

extension CampusPresenceKindX on CampusPresenceKind {
  String get firestoreValue => name;

  String get label {
    switch (this) {
      case CampusPresenceKind.arrival:
        return 'Arrived on campus';
      case CampusPresenceKind.departure:
        return 'Left campus';
    }
  }

  static CampusPresenceKind? parse(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'arrival':
        return CampusPresenceKind.arrival;
      case 'departure':
        return CampusPresenceKind.departure;
      default:
        return null;
    }
  }
}

/// Geofence for the university campus (from Firestore).
class CampusGeofence {
  const CampusGeofence({
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
    this.label = 'Campus',
    this.updatedAt,
    this.updatedByName,
  });

  final double latitude;
  final double longitude;
  final double radiusMeters;
  final String label;
  final DateTime? updatedAt;
  final String? updatedByName;

  bool get isConfigured =>
      latitude != 0 || longitude != 0;

  static CampusGeofence? fromMap(Map<String, dynamic>? data) {
    if (data == null) return null;
    final lat = (data['latitude'] as num?)?.toDouble();
    final lng = (data['longitude'] as num?)?.toDouble();
    final radius = (data['radiusMeters'] as num?)?.toDouble();
    if (lat == null || lng == null || radius == null || radius <= 0) {
      return null;
    }
    return CampusGeofence(
      latitude: lat,
      longitude: lng,
      radiusMeters: radius,
      label: (data['label'] as String?)?.trim().isNotEmpty == true
          ? (data['label'] as String).trim()
          : 'Campus',
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      updatedByName: (data['updatedByName'] as String?)?.trim(),
    );
  }
}

/// One admin campus arrival or departure row.
class CampusPresenceEvent {
  const CampusPresenceEvent({
    required this.id,
    required this.adminUid,
    required this.kind,
    required this.capturedAt,
    required this.localDateKey,
    required this.latitude,
    required this.longitude,
    this.displayName,
    this.adminEmail,
    this.staffNumber,
    this.jobTitle,
    this.deviceId,
  });

  final String id;
  final String adminUid;
  final CampusPresenceKind kind;
  final DateTime capturedAt;
  final String localDateKey;
  final double latitude;
  final double longitude;
  final String? displayName;
  final String? adminEmail;
  final String? staffNumber;
  final String? jobTitle;
  final String? deviceId;

  static CampusPresenceEvent? fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) return null;
    final kind = CampusPresenceKindX.parse(data['kind'] as String?);
    final captured = (data['capturedAt'] as Timestamp?)?.toDate();
    final dateKey = (data['localDateKey'] as String?)?.trim() ?? '';
    final uid = (data['adminUid'] as String?)?.trim() ?? '';
    if (kind == null || captured == null || dateKey.isEmpty || uid.isEmpty) {
      return null;
    }
    return CampusPresenceEvent(
      id: doc.id,
      adminUid: uid,
      kind: kind,
      capturedAt: captured,
      localDateKey: dateKey,
      latitude: (data['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (data['longitude'] as num?)?.toDouble() ?? 0,
      displayName: (data['displayName'] as String?)?.trim(),
      adminEmail: (data['adminEmail'] as String?)?.trim(),
      staffNumber: (data['staffNumber'] as String?)?.trim(),
      jobTitle: (data['jobTitle'] as String?)?.trim(),
      deviceId: (data['deviceId'] as String?)?.trim(),
    );
  }
}

/// Derived state for today's campus presence for one admin.
class AdminCampusDayStatus {
  const AdminCampusDayStatus({
    required this.localDateKey,
    required this.events,
  });

  final String localDateKey;
  final List<CampusPresenceEvent> events;

  bool get isOnCampus {
    if (events.isEmpty) return false;
    return events.last.kind == CampusPresenceKind.arrival;
  }

  CampusPresenceEvent? get lastEvent =>
      events.isEmpty ? null : events.last;

  bool get canCheckIn =>
      events.isEmpty || events.last.kind == CampusPresenceKind.departure;

  bool get canCheckOut {
    if (events.isEmpty || events.last.kind != CampusPresenceKind.arrival) {
      return false;
    }
    final now = DateTime.now();
    return localDateKeyFor(now) == localDateKey;
  }

  bool get failedToCheckOut {
    if (events.isEmpty || events.last.kind != CampusPresenceKind.arrival) {
      return false;
    }
    return localDateKeyFor(DateTime.now()).compareTo(localDateKey) > 0;
  }
}

String localDateKeyFor(DateTime local) {
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Today’s admin check-in counts for the dashboard.
class AdminCampusPresenceDashboardSummary {
  const AdminCampusPresenceDashboardSummary({
    required this.totalAdmins,
    required this.presentToday,
    required this.absentToday,
  });

  final int totalAdmins;
  final int presentToday;
  final int absentToday;
}

/// One admin on the campus presence roster (from [admins] collection).
class AdminCampusRosterEntry {
  const AdminCampusRosterEntry({
    required this.uid,
    required this.displayName,
    this.staffNumber,
    this.email,
    this.jobTitle,
  });

  final String uid;
  final String displayName;
  final String? staffNumber;
  final String? email;
  final String? jobTitle;
}
