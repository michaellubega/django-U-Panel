import 'dart:convert';


import '../../../core/auth/auth_repository.dart';
import '../../../core/auth/kiu_admin_job_title.dart';
import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/device/device_identity.dart';
import '../../../core/errors/user_facing_errors.dart';
import '../../../core/api/api_collections.dart';
import '../../../core/api/api_store.dart';
import '../../../core/storage/attendance_local_queues.dart';
import '../campus_geofence_validation.dart';
import '../campus_presence_grouping.dart';
import '../campus_presence_policy.dart';
import '../models/campus_presence_models.dart';
import 'pending_campus_presence_queue.dart';
import '../../../core/api/api_field_value.dart';
import '../../../core/api/api_datetime.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/api/api_auth.dart';
import '../../../core/api/api_config.dart';

enum CampusPresenceSubmitOutcome {
  success,
  queuedOffline,
  notAdmin,
  offline,
  geofenceNotConfigured,
  outsideCampus,
  invalidTransition,
  apiError,
}

enum CampusGeofenceSaveOutcome {
  success,
  notQaStaff,
  offline,
  invalidRadius,
  apiError,
}

class CampusPresenceRepository {
  CampusPresenceRepository._();
  static final CampusPresenceRepository instance = CampusPresenceRepository._();

  ApiStore get _db => apiStore();

  bool get _apiReady {
    try {
      return isApiConfigured;
    } catch (_) {
      return false;
    }
  }

  Future<CampusGeofence?> fetchCampusGeofence({bool forceServer = false}) async {
    final cached = await _readCachedGeofence();
    if (!_apiReady) return cached;

    final online = AppConnectivity.instance.isOnline;
    if (!online && !forceServer) return cached;
    // University meta is cached forever until the admin updates it on the server.
    if (!forceServer && cached != null) return cached;

    try {
      final ref = _db
          .collection(ApiCollections.meta)
          .doc(ApiCollections.campusGeofenceDocId);
      final snap = forceServer || online
          ? await ref.get(const ApiGetOptions(source: ApiSource.server))
          : await ref.get();
      if (!snap.exists) return cached;
      final fence =
          campusGeofenceFromFirestore(CampusGeofence.fromMap(snap.data()));
      if (fence != null) {
        await _cacheGeofence(fence);
      }
      return fence ?? cached;
    } on ApiException catch (e) {
      if (e.code == 'permission-denied') {
        throw StateError(
          UserFacingErrors.campusAreaLoadFailed,
        );
      }
      return cached;
    } catch (_) {
      return cached;
    }
  }

  Future<void> _cacheGeofence(CampusGeofence fence) async {
    await AttendanceLocalQueues.writeString(
      AttendanceLocalQueues.campusGeofenceCacheJsonKey,
      jsonEncode({
        'latitude': fence.latitude,
        'longitude': fence.longitude,
        'radiusMeters': fence.radiusMeters,
        'label': fence.label,
        if (fence.updatedByName != null) 'updatedByName': fence.updatedByName,
      }),
    );
  }

  Future<CampusGeofence?> _readCachedGeofence() async {
    final raw = await AttendanceLocalQueues.readString(
      AttendanceLocalQueues.campusGeofenceCacheJsonKey,
    );
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      return campusGeofenceFromFirestore(
        CampusGeofence.fromMap(Map<String, dynamic>.from(m)),
      );
    } catch (_) {
      return null;
    }
  }

  Future<AdminCampusDayStatus> fetchTodayStatusForCurrentAdmin() async {
    final uid = ApiAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return AdminCampusDayStatus(
        localDateKey: localDateKeyFor(DateTime.now()),
        events: const [],
      );
    }
    return fetchDayStatus(adminUid: uid, localDate: DateTime.now());
  }

  Future<AdminCampusDayStatus> fetchDayStatus({
    required String adminUid,
    required DateTime localDate,
  }) async {
    final key = localDateKeyFor(localDate);
    var serverEvents = <CampusPresenceEvent>[];
    if (_apiReady) {
      try {
        final online = AppConnectivity.instance.isOnline;
        final snap = await _db
            .collection(ApiCollections.adminCampusPresence)
            .where('adminUid', isEqualTo: adminUid)
            .where('localDateKey', isEqualTo: key)
            .orderBy('capturedAt')
            .get(
              online
                  ? const ApiGetOptions()
                  : const ApiGetOptions(source: ApiSource.serverAndCache),
            );
        serverEvents = [
          for (final d in snap.docs)
            if (CampusPresenceEvent.fromDoc(d) case final e?) e,
        ];
      } catch (_) {}
    }
    final pending = await PendingCampusPresenceQueue.eventsForAdminDate(
      adminUid: adminUid,
      localDateKey: key,
    );
    final events = _mergePresenceEvents(
      server: serverEvents,
      pending: pending,
    );
    return AdminCampusDayStatus(localDateKey: key, events: events);
  }

  List<CampusPresenceEvent> _mergePresenceEvents({
    required List<CampusPresenceEvent> server,
    required List<CampusPresenceEvent> pending,
  }) {
    final byId = <String, CampusPresenceEvent>{
      for (final e in server) e.id: e,
      for (final e in pending) e.id: e,
    };
    final out = byId.values.toList()
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    return out;
  }

  /// Loads KIU administrators who must record campus presence ([isKiuAdmin]).
  Future<List<AdminCampusRosterEntry>> fetchKiuAdminRoster() async {
    if (!_apiReady) return const [];

    final byUid = <String, AdminCampusRosterEntry>{};

    Future<void> mergeCollection(String collection) async {
      try {
        final snap = await _db.collection(collection).get();
        for (final d in snap.docs) {
          final data = d.data();
          if (data == null || !_isKiuAdminDoc(data)) continue;
          final entry = _rosterEntryFromAdminDoc(d.id, data);
          byUid.putIfAbsent(entry.uid, () => entry);
        }
      } catch (_) {}
    }

    await mergeCollection(ApiCollections.admins);
    await mergeCollection(ApiCollections.adminsLegacy);

    final out = byUid.values.toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    return out;
  }

  /// @deprecated Use [fetchKiuAdminRoster] — QA monitors KIU administrators only.
  Future<List<AdminCampusRosterEntry>> fetchAdminRoster() =>
      fetchKiuAdminRoster();

  /// Admins who have not checked in on campus today.
  Future<List<AdminCampusRosterEntry>> fetchTodayAbsentAdmins({
    DateTime? localDate,
  }) async {
    final roster = await fetchAdminRoster();
    if (roster.isEmpty) return const [];

    final day = localDate ?? DateTime.now();
    final todayKey = localDateKeyFor(day);
    final events = await fetchEventsForLocalDate(day);
    final presentUids = {
      for (final row in dayRowsForSingleLocalDate(events, todayKey))
        if (row.hasCheckIn) row.adminUid,
    };

    return [
      for (final admin in roster)
        if (!presentUids.contains(admin.uid)) admin,
    ];
  }

  /// Admins who checked in on campus today.
  Future<List<AdminCampusRosterEntry>> fetchTodayPresentAdmins({
    DateTime? localDate,
  }) async {
    final roster = await fetchAdminRoster();
    if (roster.isEmpty) return const [];

    final day = localDate ?? DateTime.now();
    final todayKey = localDateKeyFor(day);
    final events = await fetchEventsForLocalDate(day);
    final presentUids = {
      for (final row in dayRowsForSingleLocalDate(events, todayKey))
        if (row.hasCheckIn) row.adminUid,
    };

    return [
      for (final admin in roster)
        if (presentUids.contains(admin.uid)) admin,
    ];
  }

  /// Counts roster admins who checked in today vs those who have not.
  Future<AdminCampusPresenceDashboardSummary>
      fetchTodayAdminPresenceDashboardSummary() async {
    const empty = AdminCampusPresenceDashboardSummary(
      totalAdmins: 0,
      presentToday: 0,
      absentToday: 0,
    );
    if (!_apiReady) return empty;

    final roster = await fetchAdminRoster();
    if (roster.isEmpty) return empty;

    final today = DateTime.now();
    final todayKey = localDateKeyFor(today);
    final events = await fetchEventsForLocalDate(today);
    final presentUids = {
      for (final row in dayRowsForSingleLocalDate(events, todayKey))
        if (row.hasCheckIn) row.adminUid,
    };

    final present = roster.where((a) => presentUids.contains(a.uid)).length;
    final total = roster.length;
    final absent = (total - present).clamp(0, total);

    return AdminCampusPresenceDashboardSummary(
      totalAdmins: total,
      presentToday: present,
      absentToday: absent,
    );
  }

  static AdminCampusRosterEntry _rosterEntryFromAdminDoc(
    String uid,
    Map<String, dynamic> data,
  ) {
    final fullName = (data['fullName'] as String?)?.trim();
    final staffNumber = (data['registrationNumber'] as String?)?.trim();
    final email = (data['email'] as String?)?.trim();
    final displayName = (fullName != null && fullName.isNotEmpty)
        ? fullName
        : (staffNumber != null && staffNumber.isNotEmpty)
            ? staffNumber
            : (email != null && email.isNotEmpty)
                ? email
                : uid;
    return AdminCampusRosterEntry(
      uid: uid,
      displayName: displayName,
      staffNumber:
          staffNumber != null && staffNumber.isNotEmpty ? staffNumber : null,
      email: email != null && email.isNotEmpty ? email : null,
      jobTitle: KiuAdminJobTitle.normalize(
        data[AuthRepository.kiuAdminJobTitleField] as String?,
      ),
    );
  }

  static bool _isKiuAdminDoc(Map<String, dynamic> data) {
    return AuthRepository.adminDocIsKiuAdministrator(data);
  }

  Future<List<CampusPresenceEvent>> fetchEventsForLocalDate(
    DateTime localDate, {
    int limit = 200,
  }) async {
    final range = localDateRangeForPeriod(
      CampusPresenceLogPeriod.day,
      localDate,
    );
    return fetchEventsInLocalDateRange(
      rangeStart: range.start,
      rangeEnd: range.end,
      limit: limit,
    );
  }

  Future<List<CampusPresenceEvent>> fetchEventsInLocalDateRange({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    int limit = 500,
  }) async {
    if (!_apiReady) return const [];
    final start = DateTime(
      rangeStart.year,
      rangeStart.month,
      rangeStart.day,
    );
    final end = DateTime(
      rangeEnd.year,
      rangeEnd.month,
      rangeEnd.day,
      23,
      59,
      59,
      999,
    );
    try {
      final snap = await _db
          .collection(ApiCollections.adminCampusPresence)
          .where(
            'capturedAt',
            isGreaterThanOrEqualTo: apiDateToField(start),
          )
          .where(
            'capturedAt',
            isLessThanOrEqualTo: apiDateToField(end),
          )
          .orderBy('capturedAt', descending: true)
          .limit(limit)
          .get();
      return [
        for (final d in snap.docs)
          if (CampusPresenceEvent.fromDoc(d) case final e?) e,
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<List<CampusPresenceEvent>> fetchRecentEventsForAdmin({
    required String adminUid,
    int limit = 100,
  }) async {
    if (!_apiReady || adminUid.trim().isEmpty) return const [];
    try {
      final snap = await _db
          .collection(ApiCollections.adminCampusPresence)
          .where('adminUid', isEqualTo: adminUid.trim())
          .orderBy('capturedAt', descending: true)
          .limit(limit)
          .get();
      return [
        for (final d in snap.docs)
          if (CampusPresenceEvent.fromDoc(d) case final e?) e,
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<({CampusPresenceSubmitOutcome outcome, String? message})>
      submitPresence({
    required CampusPresenceKind kind,
    required double latitude,
    required double longitude,
    DateTime? capturedAt,
  }) async {
    final auth = AuthRepository.instance;
    if (!auth.isKiuAdmin) {
      return (
        outcome: CampusPresenceSubmitOutcome.notAdmin,
        message: 'Only KIU administrators can record campus check-in.',
      );
    }

    final uid = ApiAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return (
        outcome: CampusPresenceSubmitOutcome.apiError,
        message: 'You must be signed in.',
      );
    }

    final fence = await fetchCampusGeofence();
    if (fence == null || !fence.isConfigured || fence.radiusMeters <= 0) {
      return (
        outcome: CampusPresenceSubmitOutcome.geofenceNotConfigured,
        message: AppConnectivity.instance.isOnline
            ? 'Campus location is not configured. QA staff can open Campus '
                'check-in and tap Use my location (minimum 1.5 km radius).'
            : 'Campus area is not cached on this device. Connect to the internet '
                'once so QA staff can configure the campus centre, then you can '
                'check in offline.',
      );
    }

    if (!isPositionWithinCampus(fence, latitude, longitude)) {
      return (
        outcome: CampusPresenceSubmitOutcome.outsideCampus,
        message: campusDistanceMessage(fence, latitude, longitude),
      );
    }

    final when = capturedAt ?? DateTime.now();
    final transition = await _validatePresenceTransition(
      adminUid: uid,
      kind: kind,
      when: when,
    );
    if (transition.error != null) {
      return (
        outcome: CampusPresenceSubmitOutcome.invalidTransition,
        message: transition.error,
      );
    }
    final dateKey = transition.dateKey!;

    final profile = await auth.profileForCurrentUser();
    final displayName = auth.currentFullName?.trim().isNotEmpty == true
        ? auth.currentFullName!.trim()
        : profile?['fullName']?.trim();
    final email = auth.currentEmail?.trim();
    final staffNumber = auth.currentStaffNumber?.trim();
    final jobTitle = auth.currentKiuAdminJobTitle?.trim().isNotEmpty == true
        ? auth.currentKiuAdminJobTitle!.trim()
        : KiuAdminJobTitle.normalize(
            profile?[AuthRepository.kiuAdminJobTitleField],
          );
    final deviceId = await DeviceIdentity.resolve();

    final pending = PendingCampusPresenceQueue.build(
      adminUid: uid,
      kind: kind,
      capturedAt: when,
      localDateKey: dateKey,
      latitude: latitude,
      longitude: longitude,
      deviceId: deviceId,
      displayName: displayName,
      adminEmail: email,
      staffNumber: staffNumber,
      jobTitle: jobTitle,
    );

    final online = AppConnectivity.instance.isOnline;
    if (online && _apiReady) {
      try {
        final uploaded = await _writePresenceDoc(pending);
        if (uploaded) {
          return (outcome: CampusPresenceSubmitOutcome.success, message: null);
        }
        return (
          outcome: CampusPresenceSubmitOutcome.invalidTransition,
          message: kind == CampusPresenceKind.arrival
              ? 'You already checked in on campus today.'
              : 'You already checked out for today.',
        );
      } on ApiException catch (e) {
        if (e.code == 'permission-denied') {
          return (
            outcome: CampusPresenceSubmitOutcome.apiError,
            message: UserFacingErrors.campusCheckInFailed,
          );
        }
        if (e.code != 'unavailable') {
          return (
            outcome: CampusPresenceSubmitOutcome.apiError,
            message: UserFacingErrors.campusCheckInFailed,
          );
        }
      } catch (_) {}
    }

    await PendingCampusPresenceQueue.enqueue(pending);
    return (
      outcome: CampusPresenceSubmitOutcome.queuedOffline,
      message: null,
    );
  }

  /// Uploads one queued row (used by [PendingCampusPresenceSync]).
  Future<bool> uploadQueuedPresence(PendingCampusPresenceEntry entry) async {
    if (!_apiReady) return false;
    return _writePresenceDoc(entry);
  }

  Future<({String? error, String? dateKey})> _validatePresenceTransition({
    required String adminUid,
    required CampusPresenceKind kind,
    required DateTime when,
  }) async {
    AdminCampusDayStatus dayStatus;

    if (kind == CampusPresenceKind.departure) {
      final todayStatus =
          await fetchDayStatus(adminUid: adminUid, localDate: when);
      if (todayStatus.canCheckOut) {
        dayStatus = todayStatus;
      } else {
        final yesterday = when.subtract(const Duration(days: 1));
        final yesterdayStatus =
            await fetchDayStatus(adminUid: adminUid, localDate: yesterday);
        if (yesterdayStatus.failedToCheckOut) {
          return (
            error: 'Failed to check out: you did not check out before '
                'midnight on ${yesterdayStatus.localDateKey}. '
                'Check in again today to start a new day.',
            dateKey: null,
          );
        }
        if (todayStatus.events.isEmpty && !todayStatus.canCheckOut) {
          return (
            error: dayStatusMessageForDeparture(todayStatus),
            dateKey: null,
          );
        }
        dayStatus = todayStatus;
      }

      if (!dayStatus.canCheckOut) {
        return (
          error: dayStatusMessageForDeparture(dayStatus),
          dateKey: null,
        );
      }

      if (!CampusPresencePolicy.isCheckoutOnSameDayAsCheckIn(
        checkInDateKey: dayStatus.localDateKey,
        checkoutTime: when,
      )) {
        return (
          error: 'Check-out must be on the same day as check-in, before '
              'midnight. You cannot check out on the next day.',
          dateKey: null,
        );
      }

      final dayEnd =
          CampusPresencePolicy.endOfLocalDateKey(dayStatus.localDateKey);
      if (when.isAfter(dayEnd)) {
        return (
          error: 'Check-out must be before midnight on the day you checked in.',
          dateKey: null,
        );
      }
      return (error: null, dateKey: dayStatus.localDateKey);
    }

    dayStatus = await fetchDayStatus(adminUid: adminUid, localDate: when);
    if (!dayStatus.canCheckIn) {
      return (
        error: 'You are already checked in on campus today. '
            'Check out when you leave.',
        dateKey: null,
      );
    }
    return (error: null, dateKey: localDateKeyFor(when));
  }

  Future<bool> _writePresenceDoc(PendingCampusPresenceEntry entry) async {
    final ref = _db
        .collection(ApiCollections.adminCampusPresence)
        .doc(entry.id);
    final existing = await ref.get();
    if (existing.exists) return false;

    await ref.set({
      'adminUid': entry.adminUid,
      'kind': entry.kind.firestoreValue,
      'capturedAt': apiDateToField(entry.capturedAt),
      'localDateKey': entry.localDateKey,
      'latitude': entry.latitude,
      'longitude': entry.longitude,
      if (entry.displayName != null && entry.displayName!.isNotEmpty)
        'displayName': entry.displayName,
      if (entry.adminEmail != null && entry.adminEmail!.isNotEmpty)
        'adminEmail': entry.adminEmail,
      if (entry.staffNumber != null && entry.staffNumber!.isNotEmpty)
        'staffNumber': entry.staffNumber,
      if (entry.jobTitle != null && entry.jobTitle!.isNotEmpty)
        'jobTitle': entry.jobTitle,
      'deviceId': entry.deviceId,
    });
    return true;
  }

  static String dayStatusMessageForDeparture(AdminCampusDayStatus dayStatus) {
    if (dayStatus.events.isEmpty) {
      return 'Check in when you arrive on campus first.';
    }
    if (dayStatus.failedToCheckOut) {
      return 'Failed to check out before midnight. Check in again today.';
    }
    return 'You have already checked out for today.';
  }

  /// Only QA staff may set the shared campus check-in area from their device.
  Future<({CampusGeofenceSaveOutcome outcome, String? message})> saveCampusGeofence({
    required double latitude,
    required double longitude,
    required double radiusMeters,
    String label = 'Campus',
  }) async {
    final auth = AuthRepository.instance;
    if (!auth.isQaStaff) {
      return (
        outcome: CampusGeofenceSaveOutcome.notQaStaff,
        message: 'Only QA staff can update the campus check-in area and radius.',
      );
    }
    if (!AppConnectivity.instance.isOnline) {
      return (
        outcome: CampusGeofenceSaveOutcome.offline,
        message: 'Connect to the internet to update the campus location.',
      );
    }
    if (!_apiReady) {
      return (
        outcome: CampusGeofenceSaveOutcome.apiError,
        message: UserFacingErrors.backendNotReady,
      );
    }
    if (!isCampusRadiusAllowed(radiusMeters)) {
      return (
        outcome: CampusGeofenceSaveOutcome.invalidRadius,
        message: 'Radius must be at least '
            '${formatCampusRadiusMeters(campusGeofenceMinRadiusMeters)} '
            'and at most '
            '${formatCampusRadiusMeters(campusGeofenceMaxRadiusMeters)}.',
      );
    }

    final uid = ApiAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return (
        outcome: CampusGeofenceSaveOutcome.apiError,
        message: 'You must be signed in.',
      );
    }

    final profile = await auth.profileForCurrentUser();
    final displayName = auth.currentFullName?.trim().isNotEmpty == true
        ? auth.currentFullName!.trim()
        : profile?['fullName']?.trim();

    try {
      await _db
          .collection(ApiCollections.meta)
          .doc(ApiCollections.campusGeofenceDocId)
          .set(
        {
          'latitude': latitude,
          'longitude': longitude,
          'radiusMeters': radiusMeters,
          'label': label.trim().isEmpty ? 'Campus' : label.trim(),
          'updatedAt': ApiFieldValue.serverTimestamp(),
          'updatedByUid': uid,
          if (displayName != null && displayName.isNotEmpty)
            'updatedByName': displayName,
        },
        ApiSetOptions(merge: true),
      );
      return (outcome: CampusGeofenceSaveOutcome.success, message: null);
    } on ApiException catch (e) {
      if (e.code == 'permission-denied') {
        return (
          outcome: CampusGeofenceSaveOutcome.apiError,
          message: UserFacingErrors.campusAreaSaveFailed,
        );
      }
      return (
        outcome: CampusGeofenceSaveOutcome.apiError,
        message: UserFacingErrors.campusAreaSaveFailed,
      );
    } catch (e) {
      return (
        outcome: CampusGeofenceSaveOutcome.apiError,
        message: UserFacingErrors.campusAreaSaveFailed,
      );
    }
  }
}
