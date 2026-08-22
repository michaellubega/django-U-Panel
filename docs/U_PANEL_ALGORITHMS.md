# U-Panel Algorithm Catalog

Technical reference derived from the Flutter codebase at `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib`. Paths are absolute.

---

## 1. Attendance Percentage & Roll Statistics

### 1.1 Roll cell labeling (`rollCellLabelForStudentSession`)

**Purpose:** Resolve each student × session cell as `Present`, `Absent`, `Pending`, or hidden.

**Files:**
- `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\features\attendance\roll_cell_status.dart`
- `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\features\attendance\data\pending_check_in_queue.dart` (via `RollPendingContext`)

**Logic:**
1. Load pending context: offline session creates awaiting upload; queued/unverified check-ins.
2. If student has pending present for session → `Pending`.
3. Merge duplicate records for same session via `_mergeRollRecord` (prefer verified present).
4. If record exists: verified present → `Present`; unverified present → `Pending`; absent → `Absent` (only if session counts toward stats).
5. If no record: session not counting → null; session awaiting upload → `Pending`; enrolled after session ended → `Absent`; grace not expired → `Pending`; else → `Absent`.

**Inputs:** `AttendanceSession`, `studentId`, student's records, `RollPendingContext`, optional `now`.

**Outputs:** `String?` label (`Present` / `Absent` / `Pending` / null).

---

### 1.2 Attendance rate counts (`rollRateCountsForStudentOnList`)

**Purpose:** Compute present/total for percentage columns (excludes unresolved pending).

**Files:** `roll_cell_status.dart`, used by `attendance_list_roll.dart`, `attendance_screen.dart`

**Logic:**
1. Iterate completed sessions where `countsTowardRollStats`.
2. If record exists → count toward total; increment present if `record.present`.
3. If no record: skip if pending present or session awaiting upload; skip if grace not expired and not pre-join miss; else count as absent (total++).
4. Second pass: count orphan records on list not yet counted.
5. `percentRounded = round(100 * present / total).clamp(0, 100)`.

**Inputs:** `studentId`, `listId`, completed sessions, records, pending context.

**Outputs:** `RollRateCounts { present, total, percentRounded }`.

---

### 1.3 Store-level roll stats (`AttendanceStore.rollStatsForRegistrationOnList`)

**Purpose:** Profile/overall attendance % across lists for a registration number.

**Files:** `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\features\attendance\models\attendance_models.dart`

**Logic:**
1. Resolve all student IDs for normalized registration.
2. For each completed session on list (`countsTowardRollStats`), pick best record across linked student IDs (prefer present).
3. If no record: count as missed only if pre-join miss OR grace expired (`PendingRetention.sessionGraceExpired`).
4. Aggregate per-list; `rollStatsForRegistrationNormalized` sums across enrolled lists.

**Inputs:** Registration string, list ID.

**Outputs:** `AttendanceRollStats { present, total, percentRounded }`.

---

### 1.4 Consolidated roll builder (`buildAttendanceListRoll`)

**Purpose:** Build full class roll for reports/UI.

**Files:** `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\features\reports\attendance_list_roll.dart`

**Logic:** Group students by registration key, compute per-session labels and percent via roll helpers, sort by name.

**Outputs:** `AttendanceListRollData` with student rows and session label maps.

---

## 2. Geofencing & GPS Validation

### 2.1 Session check-in geofence

**Purpose:** Verify student is within session radius.

**Files:**
- `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\features\attendance\check_in_validation.dart`
- Used in `student_check_in_progress_screen.dart`, `session_code_auto_check_in.dart`, `attendance_offline_sync.dart`

**Logic:**
1. If `session.remoteLearning` → always pass.
2. Compute haversine distance via `Geolocator.distanceBetween(session center, lat, lng)`.
3. Pass if `dist <= session.radiusMeters`.

**Inputs:** `AttendanceSession`, latitude, longitude.

**Outputs:** `bool`.

---

### 2.2 Session time bounds

**Purpose:** Validate check-in timestamp against session window.

**Files:** `check_in_validation.dart`

**Logic:** `t >= startTime && t <= endTime` (inclusive). Offline replay uses **capture time**, not `DateTime.now()`.

---

### 2.3 Campus geofence (KIU admin presence)

**Purpose:** Validate KIU administrators are on campus for check-in/out.

**Files:**
- `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\features\campus_presence\campus_geofence_validation.dart`
- `campus_presence_repository.dart`

**Logic:**
1. Radius clamped to 1500–5000 m (`campusGeofenceMinRadiusMeters` / `Max`).
2. `isPositionWithinCampus`: distance from campus center ≤ configured radius.
3. Geofence cached locally for offline use; fetched from Firestore when online.

**Inputs:** `CampusGeofence`, GPS coordinates.

**Outputs:** `bool`; user-facing distance message on failure.

---

## 3. Session Code Validation

### 3.1 Format normalization & validation

**Purpose:** Accept and normalize join codes.

**Files:** `attendance_models.dart`

**Logic:**
1. `normalizeSessionCodeInput`: trim, strip spaces, uppercase.
2. `isValidJoinCodeFormat`: `###`, `####`, or `L###` (letter + 3 digits).
3. `generateSessionCode`: random 000–999.

---

### 3.2 Active session lookup (`sessionByCode` / `validateSessionCode`)

**Files:** `attendance_models.dart`, `attendance_repository.dart`

**Logic:**
1. Normalize code.
2. Find session where normalized code matches AND `isActive` (`status == active && !isExpired`).

**Outputs:** `AttendanceSession?`.

---

### 3.3 Remote resolution with retries

**Purpose:** Fetch session from Firestore when not in local store.

**Files:** `attendance_repository.dart` — `resolveActiveSessionByCodeForSignIn`, `resolveSessionByCode`, `resolveSessionByCodeAtTime`

**Logic (`resolveSessionByCodeAtTime`):**
1. Query Firestore `attendanceSessions` where `sessionCode == code`.
2. Merge docs into store.
3. Prefer session whose bounds contain `capturedAt`; fallback to best active session.
4. Load parent list if missing.

**Inputs:** Raw code, optional `capturedAt`.

**Outputs:** Matching session or null.

---

## 4. Offline Sync / Drain Pipeline

### 4.1 Coordinator

**Purpose:** Periodically drain queues while app is alive.

**Files:** `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\core\offline\pending_offline_coordinator.dart`

**Logic:**
- Every 3 minutes (and on connectivity restore / resume): call `AttendanceOfflineSync.drainAllInOrder()`.
- Urgent path: `drainCheckInsPromptly()` then full drain.
- Background sync on pause: 28s timeout.

---

### 4.2 Main drain (`AttendanceOfflineSync`)

**Files:** `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\features\attendance\data\attendance_offline_sync.dart`

**Two paths:**

| Path | Steps |
|------|-------|
| `drainCheckInsPromptly` | purge expired → session creates → check-ins → `loadAll` |
| `drainAllInOrder` | above + reconcile lists → campus presence → list creates → session codes → finalize grace → `loadAll` → notification sync |

**Concurrency:** Single-flight lock with `_drainAgain` coalescing.

**Online gate:** `hasNetworkInterface` + `ensureReachable(3s)`.

**Queue processors:**
- `PendingSessionCreateSync.drain`
- `_drainCheckInsWithoutReload`
- `PendingCampusPresenceSync.drain`
- `PendingListCreateSync.drain`
- `PendingSessionCodeSync.drainWithoutReload`

---

### 4.3 Pending check-in drain

**Logic per queued entry:**
1. Drop if retention expired.
2. Re-validate capture time and GPS against session.
3. Block duplicate device / verified duplicate.
4. Add optimistic local record if needed.
5. `trySubmitCheckInAttempt` → on success, batch `awaitOfficialRecordFromFirebase(4s timeout)`.

---

### 4.4 Session-code queue drain

**Files:** `pending_session_code_sync.dart`

**Logic:** Resolve session at capture time → validate time/radius → ensure roster sign-in → submit check-in → update queue status (`queued`, `needsRegistration`, `deviceBlocked`, removed on success/reject).

---

### 4.5 Online-first persist helper

**Files:** `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\core\connectivity\online_first_persist.dart`

**Logic:** Try online persist with timeout; on failure probe reachability and retry; else offline fallback.

---

## 5. Check-In Verification Polling

**Purpose:** Wait for Cloud Function–written official `attendanceRecords` row after submitting `checkInAttempts`.

**Files:** `attendance_repository.dart` — `awaitOfficialRecordFromFirebase`, `refreshOfficialRecordFromFirebase`, `submitStudentCheckInWithOfflineSupport`

**Logic:**
1. After successful attempt upload, poll every 300ms (online) or 600ms (offline) up to 8s/12s.
2. Each iteration: fetch official record from Firestore.
3. Exit success if `verified && present`.
4. Exit failure if official absent or `checkInAttempts` rejected → clear local unverified row.
5. Timeout → `submittedPendingVerification`.

**Inputs:** `sessionId`, `studentId`, optional timeout.

**Outputs:** `bool` verified.

---

## 6. Duplicate Device Detection

**Purpose:** Block one phone from checking in multiple students for the same session.

**Files:**
- `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\core\device\device_identity.dart`
- `attendance_models.dart` — `hasPresentCheckInForDevice`
- Check paths: `student_check_in_progress_screen.dart`, `session_code_auto_check_in.dart`, `submitStudentCheckInWithOfflineSupport`, offline drain

**Device ID resolution:**
1. Android: `androidInfo.id`; iOS: `identifierForVendor`; web/desktop: persisted random install ID in SharedPreferences.

**Duplicate check:**
```dart
attendanceRecords.any(r =>
  r.sessionId == sessionId &&
  r.studentId != currentStudent &&
  r.present &&
  r.deviceId == deviceId)
```

**Outputs:** `deviceBlocked` outcome / queue status.

---

## 7. Grace Period Logic

**Purpose:** 7-day window after session end before absent rows are finalized and pending items expire.

**Files:** `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\features\attendance\data\pending_retention.dart`, `roll_cell_status.dart`

**Constants:** `PendingRetention.unverifiedPending = Duration(days: 7)`

**Rules:**
- `sessionGraceExpired(sessionEnd, now)` ≡ `now - sessionEnd > 7 days`.
- Roll cells stay `Pending` until grace expires (unless explicit record).
- `finalizeRollForSession` only runs after grace expired.
- `finalizeGraceExpiredSessions` iterates all counting sessions past grace.

---

## 8. Pending Retention

**Purpose:** TTL for unverifiable offline queue rows.

**Files:** `pending_retention.dart`, purge in `attendance_offline_sync.dart`

**Logic:**
- `isExpired(pendingSince, now)`: age > 7 days.
- `purgeExpiredPendingOnly`:
  - Check-ins: mark absent locally, drop from queue.
  - Session codes: discard side effects, drop.
  - Session/list creates, campus presence: drop expired rows.
- `daysRemaining` for UI countdown.

---

## 9. Connectivity Probing

**Purpose:** Distinguish “has Wi‑Fi” from “Firestore reachable”.

**Files:** `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\core\connectivity\app_connectivity.dart`

**Logic:**
1. `connectivity_plus` for interface status.
2. Periodic Firestore server read: `meta/connectivityPing` with `Source.server` (6s timeout, every 30s on mobile).
3. `isOnline`: interface up AND (recent success within 25s grace OR < 2 consecutive failures).
4. `ensureReachable`: fast-path if recently reachable; else probe before critical ops.
5. Desktop/web: assume online when connectivity unknown.

**Outputs:** `hasNetworkInterface`, `firestoreReachable`, `isOnline`.

---

## 10. Notice Scheduling & Visibility

**Purpose:** Publish, schedule, filter, and deliver notices.

**Files:**
- `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\features\notices\data\notices_repository.dart`
- `create_notice_screen.dart`

**Scheduling:**
- Optional `scheduledFor` future timestamp stored in Firestore.
- `noticeEffectiveAt = scheduledFor ?? createdAt`.
- `noticeIsLive`: visible to recipients once `scheduledFor` passed.
- Admins/lecturers may preview pending scheduled notices via `noticeAllowsPendingPreview`.
- `expiresAt = base + validFor` where base is scheduled time if future else now.

**Audience matching (`noticeAudienceMatchesUser`):** Role-specific rules by `audience` (`classList`, `student`, `allAppUsers`) and `kind` (`sessionCode`, `missedsession`, `lecturertakeattendance`, etc.).

**Session-code notices:** Auto-published on session start (`publishSessionStartNotice`), 3h expiry, push enabled; suppressed for remote-learning sessions.

**Inputs:** `NoticeCreationResult`, author, user role context.

**Outputs:** Firestore doc or error string; filtered visible list client-side.

---

## 11. Auth & Role Resolution

**Purpose:** Map Firebase user to app role and capabilities.

**Files:**
- `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\core\auth\auth_repository.dart`
- `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\core\auth\user_role.dart`

**Hydration (`_hydrateUserBody`):**
1. Load `app_users/{uid}` profile (reg, name, job title).
2. Parallel role reads (unless cached for same uid):
   - `_refreshIsAdmin`: read `admins/{uid}` + legacy `admin/{uid}`; set `isAdmin`, `isQaStaff`, `isKiuAdmin` from flags and `adminRole`.
   - `_refreshIsLecturer`: read `lecturers/{uid}`; `isLecturer` from `isLecturer: true`.

**Resolved role priority:**
1. Admin check done + `isAdmin` → `qaStaff` or `admin`
2. Admin check done + `isKiuAdmin` → `kiuAdmin`
3. Lecturer check done + `isLecturer` → `lecturer`
4. Else → `student`

**Gate:** `roleCheckDone = adminCheckDone && lecturerCheckDone`.

**Outputs:** `UserRole`, capability flags (`hasStaffOperationalAccess`, `hasLecturerAttendanceAccess`).

---

## 12. List & Session Ordering

**Purpose:** Consistent UI hierarchy and roll column order.

**Files:**
- `attendance_models.dart` — `compareAttendanceListsNewestFirst`, `sessionsForListNewestFirst`
- `attendance_list_hierarchy.dart`

**List sort:** Newest first by `date` (weekday anchor), tie-break by `id` descending.

**Session sort:** Newest first by `startTime`.

**Hierarchy filters:**
- Weekend program lists only Sat/Sun.
- Group by weekday → program → year/sem.
- Lecturer scope: lists where `lecturerUid` or `createdBy` matches.

**Session eligibility for stats:** `countsTowardRollStats = now > endTime OR status == closed`.

---

## 13. Merge Logic for Records & Store Reload

### 13.1 Roll record merge (`_mergeRollRecord`)

**Files:** `roll_cell_status.dart`

**Priority:** verified present > any present > latest absent timestamp.

---

### 13.2 Firestore reload merge (`_replaceStoreFromRemote`)

**Files:** `attendance_repository.dart`

**Logic:**
1. Purge local lists not in authoritative set (remote + pending creates + referenced data).
2. Merge sessions: remote + pending session creates + active/pending local sessions.
3. Merge records map:
   - Start with remote records.
   - Preserve local unverified present unless rejected.
   - Overlay pending check-in queue rows via `_applyPendingPresentIfNotOfficial` (only if no official row yet).
4. Merge students by registration (remote + local).
5. Replace store atomically; trigger notification resync.

**Per-list partial merge:** `_mergeListDetailIntoStore` replaces one list's sessions/sign-ins/records while keeping others.

---

### 13.3 Campus presence event merge

**Files:** `campus_presence_repository.dart` — `_mergePresenceEvents`

**Logic:** Union server + pending events by ID; sort by `capturedAt`.

---

## 14. CSV & Report Generation

**Purpose:** Export attendance data as RFC-style CSV.

**Files:**
- `c:\Users\MICHAEL\Desktop\lab\U-Panel\lib\features\reports\reports_csv_data.dart`
- `attendance_list_roll.dart` — plain-text roll
- `report_download.dart` / `report_download_web.dart` — file delivery

**Builders:**

| Function | Content |
|----------|---------|
| `buildAttendanceListsSummaryCsv` | Per-list roster size, session count, present/absent rows |
| `buildSingleListRollCsv` | Student × session matrix with % column |
| `buildAttendanceRecordsCsv` | One row per attendance record |
| `buildSignInsCsv` | Roster join events |
| `buildNoticesCsv` | Notice metadata including schedule/expiry |
| `buildAttendanceListRollPlainText` | Tab-separated roll for print |

**Escaping:** `reportCsvCell` quotes fields containing comma, quote, or newline.

---

## 15. Campus Presence

**Purpose:** KIU administrator daily on-campus check-in/out with policy tags.

**Files:**
- `campus_presence_repository.dart`
- `campus_presence_policy.dart`
- `campus_geofence_validation.dart`
- `pending_campus_presence_sync.dart`

**Submit flow:**
1. Require `isKiuAdmin`.
2. Load/cache geofence; reject if outside campus.
3. `_validatePresenceTransition`: enforce one arrival per day; departure same calendar day as arrival; handle failed checkout from prior day.
4. Online → write Firestore doc; offline → enqueue `PendingCampusPresenceQueue`.
5. Drain uploads queued rows when reachable.

**Policy tags (`CampusPresencePolicy`):**
- Late arrival: after 08:30
- Early departure: before 17:00
- Overwork: after 17:30

**Absent admin list:** Compare roster vs today's arrival events.

---

## 16. Encryption / Hashing

**Finding:** No client-side password hashing or field-level encryption in app code. Authentication uses Firebase Auth (server-side). Transport encryption is standard HTTPS/Firestore.

**Non-cryptographic hashing only:**
- `NotificationIds._stableHash` — deterministic notification ID from string (Java-style string hash).
- Occasional `.hashCode` for FCM/local notification display IDs.

**Privacy copy** in `privacy_policy_screen.dart` mentions encrypted connections at infrastructure level, not app-implemented crypto.

---

## 17. Notification Scheduling

### 17.1 Lesson reminders

**Files:** `attendance_lesson_notification_scheduler.dart`, `local_notification_scheduler.dart`

**Logic:**
- 7-day lookahead over scheduled lists without same-day session.
- Lecturer: notify at lesson start time if assigned.
- QA staff: notify 1h30 after lesson start if attendance not started.
- Stable IDs via `NotificationIds.lessonLecturer` / `lessonQa`.
- Cancel stale IDs; persist snapshot for reboot resync.

---

### 17.2 Pending offline reminders

**Files:** `pending_offline_notification_scheduler.dart`

**Logic:**
- When queues non-empty, schedule local notification 24h out (reset on new work).
- Background check shows immediate notification if fire time reached and 24h since last shown.

---

### 17.3 Maintenance coordinator

**Files:** `notification_maintenance_coordinator.dart`

**Triggers:** sign-in, sign-out, attendance store updates → sync/cancel schedulers and background task registry.

---

## 18. Purge & Reconciliation

### 18.1 List reconciliation

**Files:** `attendance_repository.dart` — `reconcileDeletedListsAgainstRemote`, `reconcileLocalListsAgainstRemoteIds`

**Logic:**
1. Fetch authoritative remote list IDs for current user scope.
2. Orphans = local IDs − remote IDs − pending offline list creates.
3. `purgeListsRemovedFromRemote` → local cascade delete + topic sync.

Also triggered from `AttendanceRemoteListWatch` on live snapshot changes.

---

### 18.2 Roll finalization & absent backfill

**Files:** `finalizeRollForSession`, `_finalizeExpiredOpenSessions`

**Logic:**
1. Skip if session awaiting offline upload or grace not expired.
2. Collect roster student IDs + anyone with records.
3. Union present IDs from pending queues, local records, remote Firestore.
4. For remaining roster members without present row → create local absent record (server writes on finalize).

---

### 18.3 Expired pending purge

**Files:** `attendance_offline_sync.dart` — `purgeExpiredPendingOnly`, `_markUnverifiedCheckInAbsent`

**Logic:** Drop stale queue entries; convert expired unverified check-ins to absent locally.

---

### 18.4 Local list purge

**Files:** `AttendanceListPurge.purgeLocalDataForList`, `_purgeListLocally`

**Logic:** Remove list, sessions, sign-ins, records from in-memory store and local snapshot.

---

## 19. Additional Notable Algorithms

### Session code auto check-in (push-driven)

**Files:** `session_code_auto_check_in.dart`

**Logic:** Debounce 20s per code → validate user/format → resolve session → GPS → geofence → device check → `submitStudentCheckInWithOfflineSupport` or queue to `PendingSessionCodeQueue`.

---

### Record ID convention

**Files:** `attendance_models.dart`

**Format:** `{sessionId}_{studentId}` — one row per student per session.

---

## Summary Table

| Algorithm | Primary files |
|-----------|---------------|
| Roll % / stats | `roll_cell_status.dart`, `attendance_models.dart`, `attendance_list_roll.dart` |
| Session GPS | `check_in_validation.dart` |
| Campus GPS | `campus_geofence_validation.dart` |
| Session codes | `attendance_models.dart`, `attendance_repository.dart`, `pending_session_code_sync.dart` |
| Offline drain | `attendance_offline_sync.dart`, `pending_offline_coordinator.dart` |
| Verify polling | `attendance_repository.dart` (`awaitOfficialRecordFromFirebase`) |
| Device dedup | `device_identity.dart`, `hasPresentCheckInForDevice` |
| Grace / retention | `pending_retention.dart` |
| Connectivity | `app_connectivity.dart` |
| Notices | `notices_repository.dart` |
| Auth roles | `auth_repository.dart`, `user_role.dart` |
| Ordering | `attendance_models.dart`, `attendance_list_hierarchy.dart` |
| Store merge | `attendance_repository.dart` (`_replaceStoreFromRemote`) |
| CSV reports | `reports_csv_data.dart` |
| Campus presence | `campus_presence_repository.dart`, `campus_presence_policy.dart` |
| Notifications | `attendance_lesson_notification_scheduler.dart`, `pending_offline_notification_scheduler.dart` |
| Reconciliation | `attendance_repository.dart`, `attendance_offline_sync.dart` |

[REDACTED]

---

*Regenerate Word: python docs/_build_technical_docs.py*
