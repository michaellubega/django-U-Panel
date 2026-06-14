import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../features/attendance/models/attendance_models.dart';
import 'u_panel_rtd.dart';

/// Running (active) attendance sessions live on Realtime Database.
/// Closed sessions are archived to Firestore only.
abstract final class SessionRtdSync {
  static const _root = 'attendance_sessions';

  /// False after [MissingPluginException] until a full app rebuild.
  static bool get pluginAvailable => !uPanelRtdPluginUnavailable;

  static void markPluginUnavailable(Object error) =>
      markUPanelRtdUnavailable(error);

  static String codePath(String normalizedCode) => '$_root/by_code/$normalizedCode';

  static String idPath(String sessionId) => '$_root/by_id/$sessionId';

  static String listPath(String listId) => '$_root/by_list/$listId';

  static Map<String, Object?> buildPayload(
    AttendanceSession session, {
    String? createdByUid,
    bool locationMetadataPending = false,
  }) {
    final code = normalizeSessionCodeInput(session.sessionCode);
    return <String, Object?>{
      'id': session.id,
      'listId': session.listId,
      'sessionCode': code,
      'latitude': session.latitude,
      'longitude': session.longitude,
      'radiusMeters': session.radiusMeters,
      'startTime': session.startTime.millisecondsSinceEpoch,
      'endTime': session.endTime.millisecondsSinceEpoch,
      'status': SessionStatus.active.name,
      'createdBy': session.createdBy,
      'remoteLearning': session.remoteLearning,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      if (createdByUid != null && createdByUid.isNotEmpty)
        'createdByUid': createdByUid,
      if (locationMetadataPending) 'locationMetadataPending': true,
    };
  }

  static AttendanceSession? sessionFromRtdValue(
    String fallbackId,
    dynamic value,
  ) {
    if (value is! Map) return null;
    final map = value.map((k, v) => MapEntry(k.toString(), v));
    try {
      final id = (map['id'] as String?)?.trim();
      final startMs = map['startTime'];
      final endMs = map['endTime'];
      var start = DateTime.now();
      var end = start;
      if (startMs is num) {
        start = DateTime.fromMillisecondsSinceEpoch(startMs.toInt());
      }
      if (endMs is num) {
        end = DateTime.fromMillisecondsSinceEpoch(endMs.toInt());
      }
      final statusRaw = (map['status'] as String?)?.trim().toLowerCase();
      return AttendanceSession(
        id: (id != null && id.isNotEmpty) ? id : fallbackId,
        listId: map['listId'] as String? ?? '',
        sessionCode: map['sessionCode'] as String? ?? '',
        latitude: (map['latitude'] as num?)?.toDouble() ?? 0.0,
        longitude: (map['longitude'] as num?)?.toDouble() ?? 0.0,
        radiusMeters: (map['radiusMeters'] as num?)?.toDouble() ?? 50.0,
        startTime: start,
        endTime: end,
        status: statusRaw == 'closed'
            ? SessionStatus.closed
            : SessionStatus.active,
        createdBy: map['createdBy'] as String? ?? '',
        remoteLearning: map['remoteLearning'] == true,
        locationMetadataPending: map['locationMetadataPending'] == true,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SessionRtdSync: skip bad session $fallbackId: $e');
      }
      return null;
    }
  }

  static List<AttendanceSession> sessionsFromSnapshot(DataSnapshot snap) {
    final out = <AttendanceSession>[];
    final value = snap.value;
    if (value is! Map) return out;
    for (final entry in value.entries) {
      final session = sessionFromRtdValue(entry.key.toString(), entry.value);
      if (session != null) {
        out.add(session);
      }
    }
    out.sort((a, b) => b.startTime.compareTo(a.startTime));
    return out;
  }

  static Future<List<AttendanceSession>> fetchByCode(String rawCode) async {
    final code = normalizeSessionCodeInput(rawCode);
    if (!isValidJoinCodeFormat(code)) return const [];
    final db = tryUPanelDatabase();
    if (db == null) return const [];
    try {
      final snap = await db
          .ref(codePath(code))
          .get()
          .timeout(const Duration(seconds: 5));
      return sessionsFromSnapshot(snap);
    } on MissingPluginException catch (e) {
      markUPanelRtdUnavailable(e);
      return const [];
    } catch (e) {
      if (kDebugMode && e.toString().toLowerCase().contains('permission')) {
        debugPrint(
          'SessionRtdSync.fetchByCode permission denied for $code — '
          'deploy database.rules.json (firebase deploy --only database).',
        );
      }
      return const [];
    }
  }

  static Future<List<AttendanceSession>> fetchActiveByCode(String rawCode) async {
    final sessions = await fetchByCode(rawCode);
    return sessions.where((s) => s.isOpenForCheckIn).toList();
  }

  static Future<List<AttendanceSession>> fetchByListId(String listId) async {
    final id = listId.trim();
    if (id.isEmpty) return const [];
    final db = tryUPanelDatabase();
    if (db == null) return const [];
    try {
      final snap = await db
          .ref(listPath(id))
          .get()
          .timeout(const Duration(seconds: 5));
      return sessionsFromSnapshot(snap)
          .where((s) => s.isOpenForCheckIn)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<AttendanceSession?> fetchById(String sessionId) async {
    final id = sessionId.trim();
    if (id.isEmpty) return null;
    final db = tryUPanelDatabase();
    if (db == null) return null;
    try {
      final snap = await db
          .ref(idPath(id))
          .get()
          .timeout(const Duration(seconds: 5));
      return sessionFromRtdValue(id, snap.value);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> isRunningOnRtd(String sessionId) async {
    final session = await fetchById(sessionId);
    return session != null && session.isOpenForCheckIn;
  }

  static Future<bool> joinCodeActiveOnRtd(String normalizedCode) async {
    final active = await fetchActiveByCode(normalizedCode);
    return active.isNotEmpty;
  }

  /// Publishes a live session to RTD (not Firestore).
  static Future<bool> publishRunningSession(
    AttendanceSession session, {
    String? createdByUid,
    bool locationMetadataPending = false,
  }) async {
    if (!session.isOpenForCheckIn) return false;
    final db = tryUPanelDatabase();
    if (db == null) return false;

    final code = normalizeSessionCodeInput(session.sessionCode);
    final listId = session.listId.trim();
    final payload = buildPayload(
      session,
      createdByUid: createdByUid,
      locationMetadataPending: locationMetadataPending,
    );
    final updates = <String, Object?>{
      idPath(session.id): payload,
      if (code.isNotEmpty) '${codePath(code)}/${session.id}': payload,
      if (listId.isNotEmpty) '${listPath(listId)}/${session.id}': payload,
    };

    try {
      await db.ref().update(updates).timeout(const Duration(seconds: 8));
      return true;
    } on MissingPluginException catch (e) {
      markUPanelRtdUnavailable(e);
      return false;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SessionRtdSync.publishRunningSession failed: $e');
      }
      return false;
    }
  }

  /// Removes a running session from RTD indexes when the lecturer closes it.
  static Future<void> removeRunningSession(AttendanceSession session) async {
    final db = tryUPanelDatabase();
    if (db == null) return;
    final code = normalizeSessionCodeInput(session.sessionCode);
    final listId = session.listId.trim();
    final updates = <String, Object?>{
      idPath(session.id): null,
      if (code.isNotEmpty) '${codePath(code)}/${session.id}': null,
      if (listId.isNotEmpty) '${listPath(listId)}/${session.id}': null,
    };
    try {
      await db.ref().update(updates).timeout(const Duration(seconds: 8));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SessionRtdSync.removeRunningSession failed: $e');
      }
    }
  }

  /// Fires whenever any active session under [rawCode] is added or updated.
  static Stream<void> watchByCode(String rawCode) {
    final code = normalizeSessionCodeInput(rawCode);
    if (!isValidJoinCodeFormat(code)) {
      return const Stream<void>.empty();
    }
    final db = tryUPanelDatabase();
    if (db == null) return const Stream<void>.empty();
    return db.ref(codePath(code)).onValue.map((_) {}).handleError((Object e) {
      markUPanelRtdUnavailable(e);
    });
  }
}
