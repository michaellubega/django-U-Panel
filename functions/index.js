/**
 * U-Panel Cloud Functions (Firestore database `upanel`).
 *
 * - FCM on new notices (all_notices, list_<id>, stu_<studentId>)
 * - Deferred FCM for notices with future scheduledFor (publishDueScheduledNotices)
 * - Session notice TTL cleanup
 * - Attendance session lifecycle: finalize roll + missed notices (active/scheduled
 *   past endTime, plus client-closed sessions not yet finalized)
 * - After roll finalize: missed check-in notices + push to each absent student
 * - Reconcile check_in_attempts → attendance_records (server authority);
 *   mirrors accepted/rejected outcomes and official roll rows to Realtime Database
 *   for instant present/absent/pending counts after session close
 *   (also runs on a lease inside sessionLifecycleScheduler)
 * - Mirror attendance_sessions to Realtime Database (by join code, list, and id)
 * - Session verified but wrong time/GPS → rejected + marked absent immediately
 * - Retroactive absent backfill when a student joins a list (sign_ins trigger)
 * - Cascade delete sessions, records (by sessionId and listId), attempts,
 *   device_session_locks, sign-ins, notices (by listId, sessionId, and
 *   targetListId), and Realtime Database mirrors when a list is removed
 * - Scheduled attendance reminders (lecturer at lesson time; QA after 1:30)
 *
 * Deploy: `npm install` in `functions/`, then `firebase deploy --only functions`.
 * Optional env: `FUNCTION_REGION` (default `us-central1`).
 * Composite indexes: see repo `firestore.indexes.json` — deploy with
 * `firebase deploy --only firestore:indexes`.
 */
const {
  onDocumentCreated,
  onDocumentDeleted,
  onDocumentWritten,
} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {onValueWritten} = require("firebase-functions/v2/database");
const admin = require("firebase-admin");
const crypto = require("crypto");
const {
  getFirestore,
  FieldValue,
  Timestamp,
} = require("firebase-admin/firestore");

if (!admin.apps.length) {
  admin.initializeApp({
    databaseURL:
      "https://u-panel-2026-default-rtdb.europe-west1.firebasedatabase.app",
  });
}

const FUNCTION_REGION =
  process.env.FUNCTION_REGION || process.env.GCLOUD_REGION || "us-central1";
const ATTEMPTS_COL = "check_in_attempts";
const RECORDS_COL = "attendance_records";
const SESSIONS_COL = "attendance_sessions";
const DEVICE_LOCKS_COL = "device_session_locks";
const RTD_CHECK_IN_CONFIRMATIONS = "check_in_confirmations";
const RTD_ATTENDANCE_SESSIONS = "attendance_sessions";
const RTD_ATTENDANCE_RECORDS = "attendance_records";
const RTD_ATTENDANCE_ROLL_STATS = "attendance_roll_stats";
const RTD_STUDENT_RTD_INDEX = "student_rtd_index";
const LEASE_COL = "_function_leases";
const BATCH_WRITE_LIMIT = 400;
const GRACE_MS = 7 * 24 * 60 * 60 * 1000;
const PENDING_ATTEMPT_RETENTION_MS = GRACE_MS;
const FCM_TOPIC_SEGMENT_MAX = 200;
const FCM_SEND_MAX_ATTEMPTS = 3;

/** @returns {FirebaseFirestore.Firestore} */
function upanelDb() {
  return getFirestore(admin.app(), "upanel");
}

/**
 * @param {string} event
 * @param {Record<string, unknown>} [fields]
 */
function logInfo(event, fields = {}) {
  console.log(JSON.stringify({severity: "INFO", event, ...fields}));
}

/**
 * @param {string} event
 * @param {Record<string, unknown>} [fields]
 */
function logWarn(event, fields = {}) {
  console.warn(JSON.stringify({severity: "WARNING", event, ...fields}));
}

/**
 * @param {string} event
 * @param {unknown} err
 * @param {Record<string, unknown>} [fields]
 */
function logError(event, err, fields = {}) {
  console.error(JSON.stringify({
    severity: "ERROR",
    event,
    message: err instanceof Error ? err.message : String(err),
    ...fields,
  }));
}

/** @param {string} raw */
function sanitizeFcmTopicSegment(raw) {
  return raw.replace(/[^a-zA-Z0-9-_.~%]/g, "_");
}

/** FCM topic segment with length cap (hash suffix when truncated). */
function fcmTopicSegment(raw) {
  const sanitized = sanitizeFcmTopicSegment(String(raw || "").trim());
  if (!sanitized) return "unknown";
  if (sanitized.length <= FCM_TOPIC_SEGMENT_MAX) return sanitized;
  const hash = crypto.createHash("sha256").update(sanitized).digest("hex")
      .slice(0, 16);
  const headLen = FCM_TOPIC_SEGMENT_MAX - 1 - hash.length;
  return `${sanitized.slice(0, Math.max(1, headLen))}_${hash}`;
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} leaseId
 * @param {number} ttlMs
 * @param {() => Promise<unknown>} fn
 */
async function runWithLease(db, leaseId, ttlMs, fn) {
  const ref = db.collection(LEASE_COL).doc(leaseId);
  const now = Date.now();
  const acquired = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const untilVal = snap.exists ? snap.data()?.until : null;
    const untilMs =
      untilVal && typeof untilVal.toMillis === "function" ?
        untilVal.toMillis() :
        0;
    if (untilMs > now) return false;
    tx.set(ref, {
      until: Timestamp.fromMillis(now + ttlMs),
      owner: process.env.FUNCTION_TARGET || "local",
    });
    return true;
  });
  if (!acquired) {
    logInfo("scheduler_lease_skipped", {leaseId});
    return null;
  }
  try {
    return await fn();
  } finally {
    await ref.delete().catch(() => {});
  }
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {FirebaseFirestore.Query} query
 * @param {(docs: FirebaseFirestore.QueryDocumentSnapshot[]) => Promise<void>} pageFn
 */
async function forEachQueryPage(db, query, pageFn) {
  let last = null;
  for (;;) {
    let q = query.limit(BATCH_WRITE_LIMIT);
    if (last) q = q.startAfter(last);
    const snap = await q.get();
    if (snap.empty) break;
    await pageFn(snap.docs);
    last = snap.docs[snap.docs.length - 1];
    if (snap.size < BATCH_WRITE_LIMIT) break;
  }
}

/**
 * Normalizes Firestore Timestamp shapes from trigger snapshots.
 * @param {unknown} value
 * @returns {number|null} epoch ms, or null when absent/invalid
 */
function firestoreTimestampToMillis(value) {
  if (value == null) return null;
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (value instanceof Timestamp) return value.toMillis();
  if (typeof value.toMillis === "function") return value.toMillis();
  if (typeof value.toDate === "function") return value.toDate().getTime();
  const sec = value.seconds ?? value._seconds;
  if (typeof sec === "number") {
    const ns = value.nanoseconds ?? value._nanoseconds ?? 0;
    return sec * 1000 + Math.floor(ns / 1e6);
  }
  return null;
}

/**
 * Push copy shown on phones — plain language, no location/check-in jargon.
 * @param {Record<string, unknown>} data Firestore notice fields
 * @returns {{ title: string, body: string }}
 */
function userFacingPushCopy(data) {
  let title = (data.title || "Notice").toString().trim();
  title = title
      .replace(/^Check-in is open:\s*/i, "")
      .replace(/^Check in is open:\s*/i, "")
      .trim();
  if (!title) title = "Notice";
  if (title.length > 120) title = title.slice(0, 117) + "...";

  const kind = (data.kind || "").toString().trim().toLowerCase();

  if (kind === "missedsession") {
    let body = (data.body || "").toString().replace(/\s+/g, " ").trim();
    if (body.length > 220) body = body.slice(0, 217) + "...";
    if (!body) {
      body = "You were marked absent for a class session. Open the app to read the full notice.";
    }
    return {title, body};
  }

  if (kind === "sessioncode") {
    return {
      title,
      body: "Your class is ready. Open the app.",
    };
  }

  if (kind === "lecturertakeattendance") {
    let body = (data.body || "").toString().replace(/\s+/g, " ").trim();
    if (body.length > 220) body = body.slice(0, 217) + "...";
    if (!body) {
      body = "Your class is ready — open U-Panel and start the attendance session.";
    }
    return {title, body};
  }

  if (kind === "qastartattendance") {
    let body = (data.body || "").toString().replace(/\s+/g, " ").trim();
    if (body.length > 220) body = body.slice(0, 217) + "...";
    if (!body) {
      body =
        "A lecturer has not opened attendance 1 hour 30 minutes after lesson time. " +
        "Open U-Panel to start the session.";
    }
    return {title, body};
  }

  let body = (data.body || "").toString().replace(/\s+/g, " ").trim();
  body = body
      .replace(/open\s+attendance[^.!?]*[.!?]?/gi, "")
      .replace(/\b(location|gps)\s+check-?in\b/gi, "")
      .replace(/\b(location|gps)\b[^.!?]*[.!?]?/gi, "")
      .replace(/\bcheck-?in\b/gi, "")
      .replace(/\s+/g, " ")
      .replace(/\s+([.,!?])/g, "$1")
      .trim();

  if (body.length > 220) {
    body = body.slice(0, 217) + "...";
  }
  if (!body) {
    body = "You have a new message in the app.";
  }
  return {title, body};
}

/**
 * Mirrors Dart [AttendanceRepository.finalizeRollForSession]: roster ∪ existing
 * session rows get an absent record unless a present row exists (merge writes).
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionId
 * @param {string} listId
 */
/**
 * Loads roster sign-ins for a list in pages (course + earliest signedInAt).
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} listId
 */
async function loadSignInRosterForList(db, listId) {
  /** @type {Map<string, string>} */
  const courseByStudent = new Map();
  /** @type {Map<string, FirebaseFirestore.Timestamp>} */
  const earliestSignedInByStudent = new Map();
  await forEachQueryPage(
      db,
      db.collection("sign_ins").where("listId", "==", listId),
      async (docs) => {
        for (const doc of docs) {
          const d = doc.data() || {};
          const sid = String(d.studentId || "").trim();
          if (!sid) continue;
          courseByStudent.set(sid, String(d.course || "").trim());
          const signedAt = d.signedInAt;
          if (signedAt && typeof signedAt.toMillis === "function") {
            const prev = earliestSignedInByStudent.get(sid);
            if (!prev || signedAt.toMillis() < prev.toMillis()) {
              earliestSignedInByStudent.set(sid, signedAt);
            }
          }
        }
      },
  );
  return {courseByStudent, earliestSignedInByStudent};
}

/**
 * True when session counts toward roll (ended by time or closed).
 * @param {Record<string, unknown>} sessionData
 * @param {number} nowMs
 * @returns {boolean}
 */
function sessionCountsTowardRollStats(sessionData, nowMs) {
  const endMs = firestoreTimestampToMillis(sessionData.endTime) ?? 0;
  if (endMs > 0 && nowMs >= endMs) return true;
  return String(sessionData.status || "").trim().toLowerCase() === "closed";
}

/**
 * Later session on the same list with an official **present** row for this student.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} listId
 * @param {string} studentId
 * @param {number} sessionEndMs
 * @param {number} nowMs
 * @return {Promise<boolean>}
 */
async function studentHasLaterResolvedSessionOnList(
    db, listId, studentId, sessionEndMs, nowMs) {
  const snap = await db.collection(SESSIONS_COL)
      .where("listId", "==", listId)
      .where("endTime", ">", Timestamp.fromMillis(sessionEndMs))
      .get();
  for (const doc of snap.docs) {
    const s = doc.data() || {};
    if (!sessionCountsTowardRollStats(s, nowMs)) continue;
    const recSnap = await db.collection(RECORDS_COL)
        .doc(`${doc.id}_${studentId}`)
        .get();
    if (recSnap.exists && recSnap.data()?.present === true) return true;
  }
  return false;
}

/**
 * Per-student grace: 7-day cap after session end OR a later session resolved.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} listId
 * @param {string} studentId
 * @param {number} sessionEndMs
 * @param {FirebaseFirestore.Timestamp|undefined} signedInAt
 * @param {number} nowMs
 * @return {Promise<boolean>}
 */
async function studentSessionGraceExpired(
    db, listId, studentId, sessionEndMs, signedInAt, nowMs) {
  const signedMs =
    signedInAt && typeof signedInAt.toMillis === "function" ?
      signedInAt.toMillis() :
      0;
  const missedBeforeJoin =
    signedMs > 0 && sessionEndMs > 0 && sessionEndMs < signedMs;
  if (missedBeforeJoin) return true;
  if (sessionEndMs <= 0 || nowMs - sessionEndMs >= GRACE_MS) return true;
  return studentHasLaterResolvedSessionOnList(
      db, listId, studentId, sessionEndMs, nowMs);
}

async function finalizeRollForSessionInDb(db, sessionId, listId) {
  const sessionRef = db.collection(SESSIONS_COL).doc(sessionId);
  const sessSnap = await sessionRef.get();
  if (!sessSnap.exists) return;
  const sessData = sessSnap.data() || {};
  if (sessData.finalized === true) return;

  const emDash = "\u2014";
  const {courseByStudent, earliestSignedInByStudent} =
    await loadSignInRosterForList(db, listId);

  const sessionEndTs = sessData.endTime;
  const endMs = firestoreTimestampToMillis(sessionEndTs) ?? 0;
  const nowMs = Date.now();

  const recSnap = await db
      .collection(RECORDS_COL)
      .where("sessionId", "==", sessionId)
      .get();

  const studentIds = new Set(courseByStudent.keys());
  /** @type {Set<string>} */
  const presentIds = new Set();
  /** @type {Map<string, string>} */
  const courseFromRecord = new Map();
  for (const doc of recSnap.docs) {
    const d = doc.data() || {};
    const sid = String(d.studentId || "").trim();
    if (!sid) continue;
    studentIds.add(sid);
    if (d.present === true) presentIds.add(sid);
    const c = String(d.course || "").trim();
    if (c) courseFromRecord.set(sid, c);
  }

  const metadataMatchedSnaps = await loadMetadataMatchedAttemptSnaps(
      db,
      sessionId,
      sessData,
      listId,
  );
  for (const [sid, snap] of metadataMatchedSnaps) {
    presentIds.add(sid);
    studentIds.add(sid);
    await writePresentFromMetadataAttempt(db, sessionId, sessData, snap);
  }

  for (const doc of recSnap.docs) {
    const d = doc.data() || {};
    if (d.present === true) continue;
    const sid = String(d.studentId || "").trim();
    if (!sid) continue;
    const attemptSnap = await findMetadataMatchedAttemptSnap(
        db,
        sessionId,
        sessData,
        listId,
        sid,
    );
    if (!attemptSnap) continue;
    const ad = attemptSnap.data() || {};
    const st = String(ad.status || "").trim().toLowerCase();
    if (
      st === "accepted" ||
      checkInAttemptShouldAcceptPresent(ad, sessionId, sessData, listId)
    ) {
      presentIds.add(sid);
      studentIds.add(sid);
      await writePresentFromMetadataAttempt(
          db,
          sessionId,
          sessData,
          attemptSnap,
      );
    }
  }

  const ts = Timestamp.now();
  /** @type {{ studentId: string, course: string }[]} */
  const writes = [];
  for (const studentId of studentIds) {
    if (presentIds.has(studentId)) continue;
    let course = courseByStudent.get(studentId) || "";
    if (!course) course = courseFromRecord.get(studentId) || "";
    if (!course) course = emDash;
    writes.push({studentId, course});
  }

  let batch = db.batch();
  let n = 0;
  /** @type {{ studentId: string, course: string }[]} */
  const actualAbsentWrites = [];
  for (const {studentId, course} of writes) {
    if (metadataMatchedSnaps.has(studentId)) continue;

    const joined = earliestSignedInByStudent.get(studentId);
    const graceExpired = await studentSessionGraceExpired(
        db, listId, studentId, endMs, joined, nowMs);
    if (!graceExpired) continue;

    const ref = db.collection(RECORDS_COL).doc(`${sessionId}_${studentId}`);
    const existing = await ref.get();
    if (existing.exists && existing.data()?.present === true) continue;

    const attemptSnap = await findMetadataMatchedAttemptSnap(
        db,
        sessionId,
        sessData,
        listId,
        studentId,
    );
    if (attemptSnap) {
      const ad = attemptSnap.data() || {};
      const st = String(ad.status || "").trim().toLowerCase();
      if (
        st === "accepted" ||
        checkInAttemptShouldAcceptPresent(ad, sessionId, sessData, listId)
      ) {
        await writePresentFromMetadataAttempt(
            db,
            sessionId,
            sessData,
            attemptSnap,
        );
        continue;
      }
    }

    if (await shouldDeferAbsentForIncompleteMetadata(
        db,
        sessionId,
        sessData,
        listId,
        studentId,
    )) {
      continue;
    }

    const absentPatch = buildOfficialAbsentRecordPatch(
        existing.exists ? existing.data() : undefined,
        {sessionId, studentId, course, timestamp: ts},
    );
    if (!absentPatch) continue;

    batch.set(ref, absentPatch, {merge: true});
    actualAbsentWrites.push({studentId, course});
    n++;
    if (n >= BATCH_WRITE_LIMIT) {
      await batch.commit();
      batch = db.batch();
      n = 0;
    }
  }
  if (n > 0) {
    await batch.commit();
  }

  logInfo("finalize_roll_absents_written", {
    sessionId,
    listId,
    absentCount: actualAbsentWrites.length,
  });

  if (actualAbsentWrites.length > 0) {
    const absentTs = Date.now();
    await publishAttendanceRecordBatchToRtd(
        db,
        actualAbsentWrites.map(({studentId, course}) => ({
          sessionId,
          studentId,
          present: false,
          verified: false,
          course,
          timestampMs: absentTs,
          latitude: 0,
          longitude: 0,
          listId,
        })),
    );
    await publishSessionRollStatsToRtd(db, sessionId, listId);
    await createMissedCheckInNoticesForStudents(
        db,
        sessionId,
        listId,
        actualAbsentWrites,
        sessionEndTs,
        courseByStudent,
        earliestSignedInByStudent,
    );
  } else {
    await publishSessionRollStatsToRtd(db, sessionId, listId);
  }
}

/**
 * In-app notice + FCM (topic stu_<studentId>) for roster students on this list
 * who did not check in present for the session. Skips guests (no sign_in) and
 * students whose first sign-in on the list was after the session ended.
 * Idempotent doc id miss_<sessionId>_<studentId>.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionId
 * @param {string} listId
 * @param {{ studentId: string, course: string }[]} absentWrites
 * @param {FirebaseFirestore.Timestamp|undefined} sessionEnd
 * @param {Map<string, string>} rosterCourseByStudent sign_ins for listId
 * @param {Map<string, FirebaseFirestore.Timestamp>} earliestSignedInByStudent
 */
async function createMissedCheckInNoticesForStudents(
    db,
    sessionId,
    listId,
    absentWrites,
    sessionEnd,
    rosterCourseByStudent,
    earliestSignedInByStudent,
) {
  if (!absentWrites.length) return;
  const listSnap = await db.collection("attendance_lists").doc(listId).get();
  const list = listSnap.data() || {};
  const who = String(list.whoTaught || "").trim() || "your class";
  const lecturerForTitle = String(list.whoTaught || "").trim() || "your lecturer";
  const room = String(list.room || "").trim();
  const time = String(list.time || "").trim();
  const program = String(list.program || "day").toLowerCase();
  const progLabel = program === "evening" ? "Evening" :
    program === "weekend" ? "Weekend" : "Day";
  let dateLabel = "";
  const dateField = list.date;
  if (dateField && typeof dateField.toDate === "function") {
    const du = dateField.toDate();
    const wd = utcDartWeekdayFromDate(du);
    const names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    dateLabel = names[wd - 1] || "";
  }
  const roomBit = room ? ` · ${room}` : "";
  const classLine = [who, dateLabel, progLabel, time]
      .filter((s) => s && String(s).trim())
      .join(" · ") + roomBit;
  const targetListTitle = classLine || listId;

  const noticeTitle = `You missed a class by ${lecturerForTitle}`;

  const body =
    `You did not check in for this session (${classLine || who}). ` +
    "Warning: repeated missed check-ins lower your attendance record. " +
    "You are expected to keep attendance in good standing (typically above 75%); " +
    "falling below that can affect your eligibility to sit exams. " +
    "Attend your upcoming classes and check in as soon as the lecturer opens the session.";

  for (const {studentId} of absentWrites) {
    const sid = String(studentId || "").trim();
    if (!sid) continue;
    if (!rosterCourseByStudent.has(sid)) continue;

    const joined = earliestSignedInByStudent.get(sid);
    if (
      joined &&
      sessionEnd &&
      typeof joined.toMillis === "function" &&
      typeof sessionEnd.toMillis === "function" &&
      joined.toMillis() > sessionEnd.toMillis()
    ) {
      continue;
    }

    const noticeId = `miss_${sessionId}_${sid}`;
    const ref = db.collection("notices").doc(noticeId);
    try {
      await db.runTransaction(async (tx) => {
        const ex = await tx.get(ref);
        if (ex.exists) return;
        tx.create(ref, {
          title: noticeTitle,
          body,
          author: "U-Panel",
          createdAt: FieldValue.serverTimestamp(),
          sendPush: true,
          audience: "student",
          targetStudentId: sid,
          targetListId: listId,
          targetListTitle,
          sessionId,
          kind: "missedSession",
        });
      });
    } catch (err) {
      const code = err && err.code;
      if (code === 6 || code === "ALREADY_EXISTS") continue;
      logError("missed_notice_create_failed", err, {noticeId, sessionId, sid});
    }
  }
}

/** JS getUTCDay is 0=Sun…6=Sat; Dart [DateTime.weekday] is 1=Mon…7=Sun. */
function utcDartWeekdayFromDate(d) {
  const js = d.getUTCDay();
  return js === 0 ? 7 : js;
}

/**
 * True when every roster student has a roll row or their per-student grace ended.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionId
 * @param {string} listId
 * @param {Record<string, unknown>} sessData
 * @param {number} endMs
 * @param {number} nowMs
 * @return {Promise<boolean>}
 */
async function isSessionRollComplete(
    db, sessionId, listId, sessData, endMs, nowMs) {
  if (endMs > 0 && nowMs - endMs >= GRACE_MS) return true;

  const {courseByStudent, earliestSignedInByStudent} =
    await loadSignInRosterForList(db, listId);

  const recSnap = await db.collection(RECORDS_COL)
      .where("sessionId", "==", sessionId)
      .get();
  /** @type {Set<string>} */
  const studentIds = new Set(courseByStudent.keys());
  /** @type {Set<string>} */
  const withRecord = new Set();
  for (const doc of recSnap.docs) {
    const sid = String(doc.data()?.studentId || "").trim();
    if (!sid) continue;
    studentIds.add(sid);
    withRecord.add(sid);
  }

  for (const studentId of studentIds) {
    if (withRecord.has(studentId)) continue;
    const joined = earliestSignedInByStudent.get(studentId);
    const graceExpired = await studentSessionGraceExpired(
        db, listId, studentId, endMs, joined, nowMs);
    if (!graceExpired) return false;
    if (await shouldDeferAbsentForIncompleteMetadata(
        db, sessionId, sessData, listId, studentId)) {
      return false;
    }
  }
  return true;
}

/**
 * Finalize roll + missed notices, then mark session finalized.
 * @param {FirebaseFirestore.Firestore} db
 * @param {FirebaseFirestore.QueryDocumentSnapshot} doc
 */
async function finalizeOneSessionDoc(db, doc) {
  const data = doc.data() || {};
  if (data.finalized === true) return;
  const listId = String(data.listId || "").trim();
  try {
    await reconcilePendingAttemptsForSession(db, doc.id, data);
    const endMs = firestoreTimestampToMillis(data.endTime) ?? 0;
    const nowMs = Date.now();
    if (endMs > 0 && nowMs >= endMs && data.status !== "closed") {
      await doc.ref.update({status: "closed"});
    }
    await finalizeRollForSessionInDb(db, doc.id, listId);
    const complete = await isSessionRollComplete(
        db, doc.id, listId, data, endMs, nowMs);
    if (!complete) {
      logInfo("session_closed_pending_student_grace", {sessionId: doc.id, listId});
      return;
    }
    await doc.ref.update({
      status: "closed",
      finalized: true,
      finalizedAt: FieldValue.serverTimestamp(),
    });
    logInfo("session_finalized", {sessionId: doc.id, listId});
  } catch (e) {
    logError("finalizeOneSessionDoc_failed", e, {sessionId: doc.id, listId});
  }
}

/**
 * Close ended active/scheduled sessions, then pick up client-closed sessions
 * (app sets status closed when the lecturer ends the session) that still need
 * roll finalize + missed-lesson notices.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionsCol
 * @param {FirebaseFirestore.Timestamp} now
 */
async function closeEndedSessionsAndFinalize(db, sessionsCol, now) {
  for (const st of ["active", "scheduled"]) {
    await forEachQueryPage(
        db,
        db.collection(sessionsCol)
            .where("status", "==", st)
            .where("endTime", "<=", now),
        async (docs) => {
          for (const doc of docs) {
            await finalizeOneSessionDoc(db, doc);
          }
        },
    );
  }

  /** @type {Set<string>} */
  const closedSeen = new Set();
  try {
    await forEachQueryPage(
        db,
        db.collection(sessionsCol)
            .where("status", "==", "closed")
            .where("finalized", "==", false),
        async (docs) => {
          for (const doc of docs) {
            closedSeen.add(doc.id);
            await finalizeOneSessionDoc(db, doc);
          }
        },
    );
  } catch (e) {
    logError("closed_finalized_query_failed", e, {});
  }

  await forEachQueryPage(
      db,
      db.collection(sessionsCol).where("status", "==", "closed"),
      async (docs) => {
        for (const doc of docs) {
          if (closedSeen.has(doc.id)) continue;
          const data = doc.data() || {};
          if (data.finalized === true) continue;
          await finalizeOneSessionDoc(db, doc);
        }
      },
  );
}

/**
 * @param {Record<string, unknown>} data Firestore notice fields
 * @returns {string|null} FCM topic or null when audience is invalid
 */
function noticePushTopic(data) {
  const audience = (data.audience || "allAppUsers")
      .toString()
      .trim()
      .toLowerCase();
  if (audience === "student" || audience === "targetstudent") {
    const rawStu = (data.targetStudentId || "").toString().trim();
    if (!rawStu) {
      console.warn("student notice missing targetStudentId; skip FCM");
      return null;
    }
    return "stu_" + fcmTopicSegment(rawStu);
  }
  if (audience === "classlist" || audience === "class_list") {
    const rawId = (data.targetListId || "").toString().trim();
    if (!rawId) {
      logWarn("classlist_notice_missing_targetListId");
      return null;
    }
    return "list_" + fcmTopicSegment(rawId);
  }
  if (audience === "lecturer") {
    const rawLec = (data.targetLecturerUid || "").toString().trim();
    if (!rawLec) {
      logWarn("lecturer_notice_missing_targetLecturerUid");
      return null;
    }
    return "lec_" + fcmTopicSegment(rawLec);
  }
  if (audience === "kiuadmins" || audience === "kiu_admins") {
    return "kiu_admins";
  }
  return "all_notices";
}

/**
 * @param {string} noticeId
 * @param {Record<string, unknown>} data
 * @returns {Promise<boolean>} true when a push was sent
 */
async function sendNoticePush(noticeId, data) {
  const sendPush = data.sendPush !== false;
  if (!sendPush) {
    return false;
  }

  const kind = (data.kind || "").toString().trim().toLowerCase();
  if (kind === "sessioncode") {
    const sessionId = (data.sessionId || "").toString().trim();
    if (sessionId) {
      try {
        const sessionSnap = await upanelDb()
            .collection(SESSIONS_COL)
            .doc(sessionId)
            .get();
        if (sessionSnap.exists && sessionSnap.data()?.remoteLearning === true) {
          logInfo("fcm_push_skipped_remote_learning", {
            noticeId: String(noticeId || ""),
            sessionId,
          });
          return false;
        }
      } catch (e) {
        logWarn("remote_learning_session_lookup_failed", {
          noticeId: String(noticeId || ""),
          sessionId,
          message: e instanceof Error ? e.message : String(e),
        });
      }
    }
  }

  const topic = noticePushTopic(data);
  if (!topic) {
    return false;
  }

  const {title, body} = userFacingPushCopy(data);

  /** @type {import('firebase-admin').messaging.Message} */
  const message = {
    topic,
    notification: {title, body},
    data: {
      noticeId: String(noticeId || ""),
      kind: (data.kind || "").toString(),
      audience: (data.audience || "allAppUsers").toString(),
      sessionCode: (data.sessionCode || "").toString(),
      title,
      body,
    },
    android: {
      priority: "high",
      notification: {
        channelId: "upanel_notices",
        sound: "default",
        priority: "high",
        defaultSound: true,
      },
    },
    apns: {
      headers: {
        "apns-priority": "10",
        "apns-push-type": "alert",
      },
      payload: {aps: {sound: "default"}},
    },
  };

  for (let attempt = 1; attempt <= FCM_SEND_MAX_ATTEMPTS; attempt++) {
    try {
      const id = await admin.messaging().send(message);
      logInfo("fcm_push_sent", {
        messageId: id,
        topic,
        noticeId: String(noticeId || ""),
        attempt,
      });
      return true;
    } catch (e) {
      logError("fcm_push_failed", e, {
        topic,
        noticeId: String(noticeId || ""),
        attempt,
      });
      if (attempt < FCM_SEND_MAX_ATTEMPTS) {
        await new Promise((r) => setTimeout(r, 200 * attempt * attempt));
      }
    }
  }
  return false;
}

/**
 * @param {unknown} scheduledFor
 * @returns {boolean}
 */
function noticeScheduledForFuture(scheduledFor) {
  const ms = firestoreTimestampToMillis(scheduledFor);
  if (ms == null) return false;
  return ms > Date.now();
}

exports.onNoticeCreatedSendPush = onDocumentCreated(
  {
    document: "notices/{noticeId}",
    database: "upanel",
    region: FUNCTION_REGION,
  },
  async (event) => {
    const snap = event.data;
    if (!snap) {
      return null;
    }
    const data = snap.data() || {};
    const noticeId = String(event.params.noticeId || "");
    if (noticeScheduledForFuture(data.scheduledFor)) {
      console.log("Push deferred (scheduledFor in future)", {noticeId});
      return null;
    }
    const sent = await sendNoticePush(noticeId, data);
    if (sent) {
      await snap.ref.update({pushSentAt: FieldValue.serverTimestamp()});
    }
    return null;
  },
);

/** Sends FCM for manual notices whose scheduledFor time has arrived. */
exports.publishDueScheduledNotices = onSchedule(
  {
    schedule: "every 5 minutes",
    region: FUNCTION_REGION,
    timeZone: "UTC",
  },
  async () => {
    const db = upanelDb();
    const now = Timestamp.now();
    let sentCount = 0;
    await forEachQueryPage(
        db,
        db.collection("notices").where("scheduledFor", "<=", now),
        async (docs) => {
          for (const doc of docs) {
            const data = doc.data() || {};
            if ((data.kind || "").toString().trim().toLowerCase() !== "manual") {
              continue;
            }
            const schedMs = firestoreTimestampToMillis(data.scheduledFor);
            if (schedMs == null || schedMs > Date.now()) continue;
            if (data.pushSentAt) continue;
            if (data.sendPush === false) continue;
            const sent = await sendNoticePush(doc.id, data);
            if (sent) {
              await doc.ref.update({pushSentAt: FieldValue.serverTimestamp()});
              sentCount++;
            }
          }
        },
    );
    if (sentCount > 0) {
      logInfo("publishDueScheduledNotices", {sentCount});
    }
    return null;
  },
);

exports.deleteExpiredSessionNotices = onSchedule(
  {
    schedule: "every 15 minutes",
    region: FUNCTION_REGION,
    timeZone: "UTC",
  },
  async () => {
    const now = Timestamp.now();
    const cutoff = Timestamp.fromMillis(
        Date.now() - 3 * 60 * 60 * 1000,
    );
    const db = upanelDb();
    const byExpiry = await deleteQueryInBatches(
        db,
        db.collection("notices").where("expiresAt", "<=", now),
    );
    const bySessionCodeAge = await deleteQueryInBatches(
        db,
        db.collection("notices")
            .where("kind", "==", "sessionCode")
            .where("createdAt", "<=", cutoff),
    );
    logInfo("deleteExpiredSessionNotices", {
      byExpiry,
      bySessionCodeAge,
      total: byExpiry + bySessionCodeAge,
    });
    return null;
  },
);

/**
 * Server authority: close ended sessions and finalize roll.
 * Roll runs before `finalized` is set so a failed finalize can retry next run.
 */
exports.sessionLifecycleScheduler = onSchedule(
  {
    schedule: "every 5 minutes",
    region: FUNCTION_REGION,
    timeZone: "UTC",
  },
  async () => {
    const db = upanelDb();
    const now = Timestamp.now();
    await runWithLease(db, "sessionLifecycleScheduler", 15 * 60 * 1000,
        async () => {
          await closeEndedSessionsAndFinalize(db, SESSIONS_COL, now);
          logInfo("sessionLifecycleScheduler_done", {});
        });
    await runWithLease(db, "reconcilePendingCheckInAttempts", 15 * 60 * 1000,
        async () => {
          await reconcileAllPendingCheckInAttempts(db);
        });
    return null;
  },
);

const KAMPALA_OFFSET_MS = 3 * 60 * 60 * 1000;
const QA_ESCALATION_MS = 90 * 60 * 1000;

/** Kampala UTC offset at [utcMs] via IANA timezone (handles policy changes). */
function kampalaOffsetMsAt(utcMs) {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Africa/Kampala",
    timeZoneName: "longOffset",
  }).formatToParts(new Date(utcMs));
  const tz = parts.find((p) => p.type === "timeZoneName")?.value || "";
  const m = /GMT([+-])(\d{1,2})(?::(\d{2}))?/.exec(tz);
  if (!m) return KAMPALA_OFFSET_MS;
  const sign = m[1] === "-" ? -1 : 1;
  const hours = parseInt(m[2], 10);
  const mins = parseInt(m[3] || "0", 10);
  return sign * (hours * 3600 + mins * 60) * 1000;
}
const WEEKDAY_SHORT_TO_DART = {
  Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7,
};

/** @param {Date} date */
function getCampusDateParts(date = new Date()) {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Africa/Kampala",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  /** @type {Record<string, string>} */
  const map = {};
  for (const p of parts) {
    if (p.type !== "literal") map[p.type] = p.value;
  }
  return map;
}

/** Campus-local civil time in Africa/Kampala → UTC epoch ms. */
function campusLocalToUtcMs(y, mo, d, h, mi, s = 0) {
  const localAsUtc = Date.UTC(y, mo - 1, d, h, mi, s);
  let guess = localAsUtc - KAMPALA_OFFSET_MS;
  for (let i = 0; i < 4; i++) {
    const offset = kampalaOffsetMsAt(guess);
    const next = localAsUtc - offset;
    if (Math.abs(next - guess) < 500) return next;
    guess = next;
  }
  return guess;
}

/** @param {Record<string, string>} campusParts */
function campusDayStartUtcMs(campusParts) {
  return campusLocalToUtcMs(
      parseInt(campusParts.year, 10),
      parseInt(campusParts.month, 10),
      parseInt(campusParts.day, 10),
      0, 0, 0,
  );
}

/** @param {string} raw */
function parseListTimeMinutes(raw) {
  const t = String(raw || "").trim();
  const m = /^(\d{1,2}):(\d{2})$/.exec(t);
  if (!m) return null;
  const h = parseInt(m[1], 10);
  const min = parseInt(m[2], 10);
  if (!Number.isFinite(h) || !Number.isFinite(min)) return null;
  if (h < 0 || h > 23 || min < 0 || min > 59) return null;
  return h * 60 + min;
}

/** @param {Record<string, unknown>} list */
function listWeekdayDart(list) {
  const dateField = list.date;
  if (!dateField || typeof dateField.toDate !== "function") return null;
  return utcDartWeekdayFromDate(dateField.toDate());
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} listId
 * @param {number} dayStartUtcMs
 * @param {number} dayEndUtcMs
 */
async function listHasSessionOnCampusDay(db, listId, dayStartUtcMs, dayEndUtcMs) {
  const snap = await db.collection("attendance_sessions")
      .where("listId", "==", listId)
      .where("startTime", ">=", Timestamp.fromMillis(dayStartUtcMs))
      .where("startTime", "<", Timestamp.fromMillis(dayEndUtcMs))
      .limit(1)
      .get();
  return !snap.empty;
}

/** @param {Record<string, unknown>} list @param {Record<string, string>} campusParts */
function listClassLine(list, campusParts) {
  const who = String(list.whoTaught || "").trim() || "Lecturer";
  const room = String(list.room || "").trim();
  const time = String(list.time || "").trim();
  const program = String(list.program || "day").toLowerCase();
  const progLabel = program === "evening" ? "Evening" :
    program === "weekend" ? "Weekend" : "Day";
  const wd = listWeekdayDart(list);
  const names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  const dateLabel = wd != null ? (names[wd - 1] || "") : (campusParts.weekday || "");
  const roomBit = room ? ` · ${room}` : "";
  return [who, dateLabel, progLabel, time].filter(Boolean).join(" · ") + roomBit;
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} noticeId
 * @param {Record<string, unknown>} payload
 */
async function createNoticeIfAbsent(db, noticeId, payload) {
  const ref = db.collection("notices").doc(noticeId);
  try {
    let created = false;
    await db.runTransaction(async (tx) => {
      const ex = await tx.get(ref);
      if (ex.exists) return;
      tx.create(ref, payload);
      created = true;
    });
    return created;
  } catch (err) {
    const code = err && err.code;
    if (code === 6 || code === "ALREADY_EXISTS") return false;
    logError("notice_create_failed", err, {noticeId});
    return false;
  }
}

/**
 * Remind lecturers at scheduled lesson time; notify QA 1:30 after if still no session.
 */
exports.attendanceReminderScheduler = onSchedule(
  {
    schedule: "every 5 minutes",
    region: FUNCTION_REGION,
    timeZone: "Africa/Kampala",
  },
  async () => {
    const db = upanelDb();
    const nowMs = Date.now();
    const campusParts = getCampusDateParts(new Date(nowMs));
    const todayWd = WEEKDAY_SHORT_TO_DART[campusParts.weekday] || 0;
    if (!todayWd) return null;

    const dayStartMs = campusDayStartUtcMs(campusParts);
    const dayEndMs = dayStartMs + 24 * 60 * 60 * 1000;
    const dateKey = `${campusParts.year}${campusParts.month}${campusParts.day}`;

    await forEachQueryPage(
        db,
        db.collection("attendance_lists")
            .where("status", "in", ["draft", "active"]),
        async (listDocs) => {
          for (const doc of listDocs) {
      const list = doc.data() || {};
      const listId = doc.id;
      const listWd = listWeekdayDart(list);
      if (listWd !== todayWd) continue;

      const timeMins = parseListTimeMinutes(list.time);
      if (timeMins == null) continue;

      const scheduledMs = campusLocalToUtcMs(
          parseInt(campusParts.year, 10),
          parseInt(campusParts.month, 10),
          parseInt(campusParts.day, 10),
          Math.floor(timeMins / 60),
          timeMins % 60,
      );

      if (nowMs < scheduledMs || nowMs >= dayEndMs) continue;

      const hasSession = await listHasSessionOnCampusDay(
          db, listId, dayStartMs, dayEndMs,
      );
      if (hasSession) continue;

      const classLine = listClassLine(list, campusParts);
      const unitName = String(list.courseUnitName || "").trim();
      const title = unitName || classLine || listId;
      const lecturerUid = String(list.lecturerUid || "").trim();
      const whoTaught = String(list.whoTaught || "").trim() || "the lecturer";
      const scheduledTs = Timestamp.fromMillis(scheduledMs);
      const expiresAt = Timestamp.fromMillis(dayEndMs + 2 * 60 * 60 * 1000);

      if (nowMs >= scheduledMs) {
        const lectId = `lectAtt_${listId}_${dateKey}`;
        if (lecturerUid) {
          await createNoticeIfAbsent(db, lectId, {
            title: `Start attendance: ${title}`,
            body:
              `Your class (${classLine}) was scheduled for ${String(list.time || "").trim()}. ` +
              "Open U-Panel and start the attendance session now.",
            author: "U-Panel",
            createdAt: FieldValue.serverTimestamp(),
            sendPush: true,
            audience: "lecturer",
            targetLecturerUid: lecturerUid,
            targetListId: listId,
            targetListTitle: classLine || title,
            scheduledSlotAt: scheduledTs,
            kind: "lecturerTakeAttendance",
            expiresAt,
          });
        }
      }

      if (nowMs >= scheduledMs + QA_ESCALATION_MS) {
        const qaId = `qaAtt_${listId}_${dateKey}`;
        await createNoticeIfAbsent(db, qaId, {
          title: `Attendance not started: ${title}`,
          body:
            `${whoTaught} has not opened attendance for ${classLine || title} ` +
            `(scheduled ${String(list.time || "").trim()}). It is 1 hour 30 minutes past ` +
            "lesson time — QA can start the session in the app.",
          author: "U-Panel",
          createdAt: FieldValue.serverTimestamp(),
          sendPush: true,
          audience: "allAppUsers",
          targetListId: listId,
          targetListTitle: classLine || title,
          targetLecturerUid: lecturerUid || null,
          scheduledSlotAt: scheduledTs,
          kind: "qaStartAttendance",
          expiresAt,
        });
      }
          }
        },
    );
    return null;
  },
);

/**
 * @param {FirebaseFirestore.Timestamp|undefined} capturedAt
 * @param {FirebaseFirestore.Timestamp|undefined} clientSubmittedAt
 */
function pendingAttemptRetentionExpired(capturedAt, clientSubmittedAt) {
  const now = Date.now();
  const ts = capturedAt || clientSubmittedAt;
  if (!ts || typeof ts.toMillis !== "function") return false;
  return now - ts.toMillis() > PENDING_ATTEMPT_RETENTION_MS;
}

/**
 * @param {Record<string, unknown>} data
 * @return {boolean}
 */
function attemptRetentionExpired(data) {
  const untilMs =
    data.pendingUntil && typeof data.pendingUntil.toMillis === "function" ?
      data.pendingUntil.toMillis() :
      null;
  if (untilMs != null) return Date.now() > untilMs;
  return pendingAttemptRetentionExpired(
      data.capturedAt,
      data.clientSubmittedAt,
  );
}

/**
 * @param {Record<string, unknown>} data
 * @return {boolean}
 */
function hasCompleteStudentAttemptMetadata(data) {
  const code = normalizeSessionCode(
      data.sessionCodeRaw || data.sessionCode || "",
  );
  const lat = Number(data.latitude);
  const lng = Number(data.longitude);
  return Boolean(
      data.capturedAt &&
      code &&
      isValidCheckInCoordinates(lat, lng),
  );
}

/**
 * Pending is only valid while student/session linkage metadata is still missing.
 * @param {Record<string, unknown>} data
 * @return {boolean}
 */
function studentAttemptMissingMetadataForPending(data) {
  if (!hasCompleteStudentAttemptMetadata(data)) return true;
  if (data.awaitingSession === true) return true;
  if (!String(data.sessionId || "").trim()) return true;
  return false;
}

/**
 * @param {Record<string, unknown>|undefined} existingData
 * @param {object} opts
 * @return {Record<string, unknown>|null}
 */
function buildOfficialPresentRecordPatch(
    existingData,
    {
      sessionId,
      studentId,
      course,
      capturedAt,
      latitude,
      longitude,
      deviceId,
      metadataMatchedPresent,
    },
) {
  const prev = existingData || {};
  const upgradingFromAbsent = prev.present !== true;

  if (prev.present === true && !upgradingFromAbsent) {
    /** @type {Record<string, unknown>} */
    const fill = {};
    if (!String(prev.course || "").trim() && course) fill.course = course;
    if (!prev.timestamp && capturedAt) fill.timestamp = capturedAt;
    const prevLat = Number(prev.latitude);
    const prevLng = Number(prev.longitude);
    if (
      !isValidCheckInCoordinates(prevLat, prevLng) &&
      isValidCheckInCoordinates(latitude, longitude)
    ) {
      fill.latitude = latitude;
      fill.longitude = longitude;
    }
    if (!String(prev.deviceId || "").trim() && deviceId) {
      fill.deviceId = deviceId;
    }
    if (Object.keys(fill).length === 0) return null;
    fill.serverReceivedAt = FieldValue.serverTimestamp();
    return fill;
  }

  if (!capturedAt) return null;

  /** @type {Record<string, unknown>} */
  const patch = {
    sessionId,
    studentId,
    present: true,
    verified: true,
    course: course || "\u2014",
    timestamp: capturedAt,
    latitude,
    longitude,
    serverReceivedAt: FieldValue.serverTimestamp(),
  };
  if (deviceId) patch.deviceId = deviceId;
  if (metadataMatchedPresent) patch.metadataMatchedPresent = true;
  return patch;
}

/**
 * @param {Record<string, unknown>|undefined} existingData
 * @param {object} opts
 * @return {Record<string, unknown>|null}
 */
function buildOfficialAbsentRecordPatch(
    existingData,
    {sessionId, studentId, course, timestamp},
) {
  const prev = existingData || {};
  if (prev.present === true) return null;

  /** @type {Record<string, unknown>} */
  const patch = {
    sessionId,
    studentId,
    present: false,
    verified: false,
    serverReceivedAt: FieldValue.serverTimestamp(),
  };
  if (!String(prev.course || "").trim() && course) {
    patch.course = course;
  }
  if (!prev.timestamp && timestamp) {
    patch.timestamp = timestamp;
  }
  const prevLat = Number(prev.latitude);
  const prevLng = Number(prev.longitude);
  if (!isValidCheckInCoordinates(prevLat, prevLng)) {
    patch.latitude = 0;
    patch.longitude = 0;
  }
  return patch;
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionId
 * @param {Record<string, unknown>} session
 * @param {string} studentId
 * @return {Promise<boolean>}
 */
async function hasUnexpiredAwaitingStudentClaim(
    db,
    sessionId,
    session,
    studentId,
) {
  const code = normalizeSessionCode(session.sessionCode || "");
  if (!code || !studentId) return false;
  const docId = `await_${code}_${studentId}`;
  const snap = await db.collection(ATTEMPTS_COL).doc(docId).get();
  if (!snap.exists) return false;
  const d = snap.data() || {};
  if (String(d.status || "").trim().toLowerCase() !== "pending") return false;
  if (d.awaitingSession !== true) return false;
  return !attemptRetentionExpired(d);
}

/**
 * Defer absent writes while any unexpired check-in evidence is still pending.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionId
 * @param {Record<string, unknown>} session
 * @param {string} listId
 * @param {string} studentId
 * @return {Promise<boolean>}
 */
async function shouldDeferAbsentForIncompleteMetadata(
    db,
    sessionId,
    session,
    listId,
    studentId,
) {
  if (await hasUnexpiredAwaitingStudentClaim(
      db,
      sessionId,
      session,
      studentId,
  )) {
    return true;
  }

  /** @param {FirebaseFirestore.DocumentSnapshot} snap */
  const isDeferrable = (snap) => {
    if (!snap.exists) return false;
    const d = snap.data() || {};
    if (String(d.studentId || "").trim() !== studentId) return false;
    const st = String(d.status || "").trim().toLowerCase();
    if (st !== "pending") return false;
    return !attemptRetentionExpired(d);
  };

  for (const id of metadataMatchedAttemptDocIds(sessionId, session, studentId)) {
    const snap = await db.collection(ATTEMPTS_COL).doc(id).get();
    if (isDeferrable(snap)) return true;
  }

  const bySession = await db.collection(ATTEMPTS_COL)
      .where("studentId", "==", studentId)
      .where("sessionId", "==", sessionId)
      .where("status", "==", "pending")
      .limit(8)
      .get();
  for (const doc of bySession.docs) {
    if (isDeferrable(doc)) return true;
  }

  const code = normalizeSessionCode(session.sessionCode || "");
  if (code) {
    const byCode = await db.collection(ATTEMPTS_COL)
        .where("studentId", "==", studentId)
        .where("sessionCodeRaw", "==", code)
        .where("status", "==", "pending")
        .limit(8)
        .get();
    for (const doc of byCode.docs) {
      if (isDeferrable(doc)) return true;
    }
  }

  return false;
}

/** @param {number} lat1 @param {number} lon1 @param {number} lat2 @param {number} lon2 */
function distanceMeters(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(lat1)) *
      Math.cos(toRad(lat2)) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);
  return 2 * R * Math.asin(Math.sqrt(a));
}

/** @param {Record<string, unknown>} session */
function isSessionOpenForCheckIn(session) {
  return String(session.status || "").trim().toLowerCase() === "active";
}

/**
 * Matches Dart [isTimestampWithinSessionBounds]: inclusive start/end, plus the
 * brief post-endTime window while the lecturer has not closed the session.
 * @param {Record<string, unknown>} session
 * @param {FirebaseFirestore.Timestamp} capturedAt
 */
function isTimestampWithinSessionBounds(session, capturedAt) {
  const startMs = firestoreTimestampToMillis(session.startTime);
  const endMs = firestoreTimestampToMillis(session.endTime);
  const t = firestoreTimestampToMillis(capturedAt);
  if (startMs == null || endMs == null || t == null) return false;
  if (t < startMs) return false;
  if (t <= endMs) return true;
  return isSessionOpenForCheckIn(session);
}

function isValidCheckInCoordinates(lat, lng) {
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return false;
  if (Math.abs(lat) < 0.001 && Math.abs(lng) < 0.001) return false;
  return true;
}

/** @param {Record<string, unknown>} session */
function isSessionGeofenceConfigured(session) {
  if (session.remoteLearning === true) return true;
  if (session.locationMetadataPending === true) return false;
  const radius = Number(session.radiusMeters);
  if (!Number.isFinite(radius) || radius <= 0) return false;
  const centerLat = Number(session.latitude);
  const centerLng = Number(session.longitude);
  return isValidCheckInCoordinates(centerLat, centerLng);
}

/** Explicit remote learning or lecturer location not set — skip GPS checks. */
function sessionSkipsLocationCheck(session) {
  if (session.remoteLearning === true) return true;
  if (session.locationMetadataPending === true) return true;
  return !isSessionGeofenceConfigured(session);
}

/**
 * @param {Record<string, unknown>} session
 * @param {number} lat
 * @param {number} lng
 */
function isPositionWithinSession(session, lat, lng) {
  if (sessionSkipsLocationCheck(session)) return true;
  if (!isValidCheckInCoordinates(lat, lng)) return false;
  const centerLat = Number(session.latitude);
  const centerLng = Number(session.longitude);
  const radius = Number(session.radiusMeters);
  return distanceMeters(centerLat, centerLng, lat, lng) <= radius;
}

/**
 * Offline capture trust: session link + join code + capture time are enough;
 * do not reject for shifted geofence or lecturer metadata updates after capture.
 * @param {Record<string, unknown>} attemptData
 * @param {string} sessionId
 * @param {Record<string, unknown>} session
 */
function checkInAttemptTrustOfflineCapture(attemptData, sessionId, session) {
  if (!attemptData.capturedAt) return false;
  const sid = String(sessionId || "").trim();
  if (!sid) return false;
  const hinted = String(attemptData.sessionId || "").trim();
  if (hinted && hinted !== sid) return false;
  const attemptListId = String(attemptData.listId || "").trim();
  const sessionListId = String(session.listId || "").trim();
  if (attemptListId && sessionListId && attemptListId !== sessionListId) {
    return false;
  }
  const attemptCode = normalizeSessionCode(
      attemptData.sessionCodeRaw || attemptData.sessionCode || "",
  );
  const sessionCode = normalizeSessionCode(session.sessionCode || "");
  if (attemptCode && sessionCode && attemptCode === sessionCode) {
    return true;
  }
  return hinted === sid;
}

/**
 * Accept present when strict metadata matches OR offline-trusted evidence.
 * @param {Record<string, unknown>} attemptData
 * @param {string} sessionId
 * @param {Record<string, unknown>} session
 * @param {string} listId
 */
function checkInAttemptShouldAcceptPresent(
    attemptData,
    sessionId,
    session,
    listId,
) {
  if (checkInAttemptQualifiesForPresentCorrection(attemptData, session, listId)) {
    return true;
  }
  return checkInAttemptTrustOfflineCapture(attemptData, sessionId, session);
}

/**
 * True when check-in evidence aligns with session + list (time, code, GPS, list).
 * Students matching this must never receive an absent roll row.
 * @param {Record<string, unknown>} attemptData
 * @param {Record<string, unknown>} session
 * @param {string} listId
 */
function checkInAttemptMatchesSessionMetadata(attemptData, session, listId) {
  if (!attemptData.capturedAt) return false;
  const sessionListId = String(session.listId || "").trim();
  const attemptListId = String(attemptData.listId || "").trim();
  const scopeListId = String(listId || "").trim();
  if (scopeListId && sessionListId && scopeListId !== sessionListId) {
    return false;
  }
  if (attemptListId && sessionListId && attemptListId !== sessionListId) {
    return false;
  }
  if (attemptListId && scopeListId && attemptListId !== scopeListId) {
    return false;
  }

  const attemptCode = normalizeSessionCode(
      attemptData.sessionCodeRaw || attemptData.sessionCode || "",
  );
  const sessionCode = normalizeSessionCode(session.sessionCode || "");
  if (attemptCode && sessionCode && attemptCode !== sessionCode) {
    return false;
  }

  if (!isTimestampWithinSessionBounds(session, attemptData.capturedAt)) {
    return false;
  }
  if (sessionSkipsLocationCheck(session)) {
    return true;
  }
  const lat = Number(attemptData.latitude);
  const lng = Number(attemptData.longitude);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return false;
  return isPositionWithinSession(session, lat, lng);
}

/**
 * When correcting an official absent row, accept code + capture time + GPS
 * even if the session geofence centre was misconfigured server-side.
 * @param {Record<string, unknown>} attemptData
 * @param {Record<string, unknown>} session
 * @param {string} listId
 */
function checkInAttemptQualifiesForPresentCorrection(
    attemptData,
    session,
    listId,
) {
  if (checkInAttemptMatchesSessionMetadata(attemptData, session, listId)) {
    return true;
  }
  if (!attemptData.capturedAt) return false;
  const sessionListId = String(session.listId || "").trim();
  const attemptListId = String(attemptData.listId || "").trim();
  const scopeListId = String(listId || "").trim();
  if (scopeListId && sessionListId && scopeListId !== sessionListId) {
    return false;
  }
  if (attemptListId && sessionListId && attemptListId !== sessionListId) {
    return false;
  }
  if (attemptListId && scopeListId && attemptListId !== scopeListId) {
    return false;
  }
  const attemptCode = normalizeSessionCode(
      attemptData.sessionCodeRaw || attemptData.sessionCode || "",
  );
  const sessionCode = normalizeSessionCode(session.sessionCode || "");
  if (attemptCode && sessionCode && attemptCode !== sessionCode) {
    return false;
  }
  if (!isTimestampWithinSessionBounds(session, attemptData.capturedAt)) {
    return false;
  }
  const lat = Number(attemptData.latitude);
  const lng = Number(attemptData.longitude);
  if (!isValidCheckInCoordinates(lat, lng)) return false;
  if (session.remoteLearning === true) return true;
  if (!isSessionGeofenceConfigured(session)) return true;
  return isPositionWithinSession(session, lat, lng);
}

/**
 * Doc ids for check-in attempts (standard row + pre-session `await_CODE_student`).
 * @param {string} sessionId
 * @param {Record<string, unknown>} session
 * @param {string} studentId
 * @return {string[]}
 */
function metadataMatchedAttemptDocIds(sessionId, session, studentId) {
  const ids = [`${sessionId}_${studentId}`];
  const code = normalizeSessionCode(session.sessionCode);
  if (code) ids.push(`await_${code}_${studentId}`);
  return ids;
}

/**
 * Finds a pending/accepted attempt whose metadata matches [session] for [studentId].
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionId
 * @param {Record<string, unknown>} session
 * @param {string} listId
 * @param {string} studentId
 * @returns {Promise<FirebaseFirestore.DocumentSnapshot|null>}
 */
async function findMetadataMatchedAttemptSnap(
    db,
    sessionId,
    session,
    listId,
    studentId,
) {
  /** @type {Set<string>} */
  const seen = new Set();
  /** @param {FirebaseFirestore.DocumentSnapshot} snap */
  const pick = (snap) => {
    if (!snap.exists || seen.has(snap.id)) return null;
    seen.add(snap.id);
    const d = snap.data() || {};
    const st = String(d.status || "").trim().toLowerCase();
    if (st === "accepted") return snap;
    if (st === "rejected") {
      return checkInAttemptShouldAcceptPresent(d, sessionId, session, listId) ?
        snap :
        null;
    }
    if (
      st === "pending" &&
      checkInAttemptShouldAcceptPresent(d, sessionId, session, listId)
    ) {
      return snap;
    }
    return null;
  };

  for (const id of metadataMatchedAttemptDocIds(sessionId, session, studentId)) {
    const hit = pick(await db.collection(ATTEMPTS_COL).doc(id).get());
    if (hit) return hit;
  }

  const bySession = await db.collection(ATTEMPTS_COL)
      .where("studentId", "==", studentId)
      .where("sessionId", "==", sessionId)
      .limit(16)
      .get();
  for (const doc of bySession.docs) {
    const hit = pick(doc);
    if (hit) return hit;
  }

  const code = normalizeSessionCode(session.sessionCode);
  if (code) {
    const byCode = await db.collection(ATTEMPTS_COL)
        .where("studentId", "==", studentId)
        .where("sessionCodeRaw", "==", code)
        .limit(16)
        .get();
    for (const doc of byCode.docs) {
      const hit = pick(doc);
      if (hit) return hit;
    }
  }

  return null;
}

/**
 * Writes an official present row from metadata-matched attempt evidence.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionId
 * @param {Record<string, unknown>} session
 * @param {FirebaseFirestore.DocumentSnapshot} attemptSnap
 */
async function writePresentFromMetadataAttempt(
    db,
    sessionId,
    session,
    attemptSnap,
) {
  const data = attemptSnap.data() || {};
  const studentId = String(data.studentId || "").trim();
  if (!studentId) return;

  const recordRef = db.collection(RECORDS_COL).doc(`${sessionId}_${studentId}`);
  const existing = await recordRef.get();
  const prev = existing.data() || {};

  const lat = Number(data.latitude);
  const lng = Number(data.longitude);
  const course = String(data.course || "").trim() || "\u2014";
  const capturedAt = data.capturedAt;
  const deviceId = String(data.deviceId || "").trim();
  if (!deviceId) return;

  const claim = await claimDeviceForSessionPresent(db, {
    sessionId,
    listId: String(session.listId || "").trim(),
    deviceId,
    studentId,
    attemptId: attemptSnap.id,
    capturedAt,
  });
  if (!claim.allowed) {
    const st = String(data.status || "").trim().toLowerCase();
    if (st === "pending") {
      const rejectionReason = claim.reason ||
          "Device already used for another student this session.";
      await attemptSnap.ref.update({
        status: "rejected",
        rejectionReason,
        sessionId,
        processedAt: FieldValue.serverTimestamp(),
      });
      await publishCheckInConfirmationToRtd({
        sessionId,
        studentId,
        status: "rejected",
        present: false,
        verified: false,
        rejectionReason,
        recordId: attemptSnap.id,
      });
    }
    return;
  }
  if (claim.supersededStudentId) {
    await revokeDeviceSupersededCheckIn(db, {
      sessionId,
      supersededStudentId: claim.supersededStudentId,
      reason: "Device claimed by an earlier check-in on this session.",
    });
  }

  const presentPatch = buildOfficialPresentRecordPatch(prev, {
    sessionId,
    studentId,
    course,
    capturedAt,
    latitude: lat,
    longitude: lng,
    deviceId,
    metadataMatchedPresent: true,
  });
  if (!presentPatch) {
    if (prev.present === true &&
        String(data.status || "").trim().toLowerCase() === "pending") {
      await attemptSnap.ref.update({
        status: "accepted",
        sessionId,
        listId: String(session.listId || data.listId || "").trim(),
        processedAt: FieldValue.serverTimestamp(),
      });
      await publishCheckInConfirmationToRtd({
        sessionId,
        studentId,
        status: "accepted",
        present: true,
        verified: true,
        recordId: attemptSnap.id,
      });
    }
    return;
  }

  await recordRef.set(presentPatch, {merge: true});

  await attemptSnap.ref.update({
    status: "accepted",
    sessionId,
    listId: String(session.listId || data.listId || "").trim(),
    processedAt: FieldValue.serverTimestamp(),
  });
  await publishCheckInConfirmationToRtd({
    sessionId,
    studentId,
    status: "accepted",
    present: true,
    verified: true,
    recordId: attemptSnap.id,
  });
  await publishAttendanceRecordToRtd(db, {
    sessionId,
    studentId,
    present: true,
    verified: true,
    course,
    timestampMs: firestoreTimestampToMillis(capturedAt) ?? Date.now(),
    latitude: lat,
    longitude: lng,
    deviceId,
    recordId: `${sessionId}_${studentId}`,
    listId: String(session.listId || data.listId || "").trim(),
  });
  const listId = String(session.listId || data.listId || "").trim();
  if (listId) {
    await publishSessionRollStatsToRtd(db, sessionId, listId);
  }
}

/**
 * Students with pending attempts whose metadata matches the session.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionId
 * @param {Record<string, unknown>} session
 * @param {string} listId
 * @returns {Promise<Map<string, FirebaseFirestore.DocumentSnapshot>>}
 */
async function loadMetadataMatchedAttemptSnaps(
    db,
    sessionId,
    session,
    listId,
) {
  /** @type {Map<string, FirebaseFirestore.DocumentSnapshot>} */
  const matched = new Map();

  const consider = (doc) => {
    const d = doc.data() || {};
    const status = String(d.status || "").trim().toLowerCase();
    if (status === "rejected") {
      if (checkInAttemptShouldAcceptPresent(d, sessionId, session, listId)) {
        const sid = String(d.studentId || "").trim();
        if (sid) matched.set(sid, doc);
      }
      return;
    }
    if (studentAttemptMissingMetadataForPending(d)) return;
    if (!checkInAttemptShouldAcceptPresent(d, sessionId, session, listId)) {
      return;
    }
    const sid = String(d.studentId || "").trim();
    if (sid) matched.set(sid, doc);
  };

  await forEachQueryPage(
      db,
      db.collection(ATTEMPTS_COL)
          .where("sessionId", "==", sessionId)
          .where("status", "==", "pending"),
      async (docs) => {
        for (const doc of docs) consider(doc);
      },
  );

  const code = normalizeSessionCode(session.sessionCode);
  if (code) {
    await forEachQueryPage(
        db,
        db.collection(ATTEMPTS_COL)
            .where("status", "==", "pending")
            .where("sessionCodeRaw", "==", code),
        async (docs) => {
          for (const doc of docs) {
            const d = doc.data() || {};
            if (String(d.sessionId || "").trim() === sessionId) {
              consider(doc);
              continue;
            }
            const attemptCode = normalizeSessionCode(
                d.sessionCodeRaw || d.sessionCode,
            );
            if (attemptCode !== code) continue;
            consider(doc);
          }
        },
    );
  }

  return matched;
}

/** @param {string} raw */
function normalizeSessionCode(raw) {
  return String(raw || "").trim().replace(/\s+/g, "").toUpperCase();
}

/**
 * @param {string} sessionId
 * @returns {Promise<Record<string, unknown>|null>}
 */
async function loadRunningSessionFromRtd(sessionId) {
  const sid = String(sessionId || "").trim();
  if (!sid) return null;
  try {
    const snap = await admin.database()
        .ref(`${RTD_ATTENDANCE_SESSIONS}/by_id/${sid}`)
        .get();
    const val = snap.val();
    if (!val || typeof val !== "object") return null;
    if (String(val.status || "").trim().toLowerCase() !== "active") return null;
    return val;
  } catch (e) {
    logWarn("loadRunningSessionFromRtd_failed", {sessionId: sid, error: String(e)});
    return null;
  }
}

/**
 * Resolves listId for a running session (RTD first, then Firestore archive).
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionId
 * @returns {Promise<string>}
 */
async function resolveListIdForSessionId(db, sessionId) {
  const sid = String(sessionId || "").trim();
  if (!sid) return "";
  const rtdSession = await loadRunningSessionFromRtd(sid);
  if (rtdSession) {
    const fromRtd = String(rtdSession.listId || "").trim();
    if (fromRtd) return fromRtd;
  }
  try {
    const sessSnap = await db.collection(SESSIONS_COL).doc(sid).get();
    if (sessSnap.exists) {
      return String(sessSnap.data()?.listId || "").trim();
    }
  } catch (e) {
    logWarn("resolveListIdForSessionId_failed", {sessionId: sid, error: String(e)});
  }
  return "";
}

/**
 * @param {string} code
 * @returns {Promise<Array<{sessionId: string, session: Record<string, unknown>}>>}
 */
async function loadRunningSessionsByCodeFromRtd(code) {
  const normalized = normalizeSessionCode(code);
  if (!normalized) return [];
  try {
    const snap = await admin.database()
        .ref(`${RTD_ATTENDANCE_SESSIONS}/by_code/${normalized}`)
        .get();
    const val = snap.val();
    if (!val || typeof val !== "object") return [];
    /** @type {Array<{sessionId: string, session: Record<string, unknown>}>} */
    const out = [];
    for (const [sessionId, session] of Object.entries(val)) {
      if (!session || typeof session !== "object") continue;
      if (String(session.status || "").trim().toLowerCase() !== "active") continue;
      out.push({sessionId, session});
    }
    return out;
  } catch (e) {
    logWarn("loadRunningSessionsByCodeFromRtd_failed", {code: normalized, error: String(e)});
    return [];
  }
}

/**
 * Resolve session by doc id or by sessionCode / sessionCodeRaw on the attempt.
 * Online running sessions live on RTD; offline-started sessions are uploaded to
 * Firestore (onAttendanceSessionWritten reconciles pending check-ins from there).
 * Closed/archived sessions are always read from Firestore.
 * @param {FirebaseFirestore.Firestore} db
 * @param {Record<string, unknown>} data
 * @returns {Promise<{sessionId: string, session: Record<string, unknown>}|null>}
 */
async function resolveSessionForAttempt(db, data) {
  const capturedAt = data.capturedAt;
  const sessionIdRaw = String(data.sessionId || "").trim();
  if (sessionIdRaw) {
    const rtdSession = await loadRunningSessionFromRtd(sessionIdRaw);
    if (rtdSession) {
      const attemptCode = normalizeSessionCode(
          data.sessionCodeRaw || data.sessionCode || "",
      );
      const sessionCode = normalizeSessionCode(rtdSession.sessionCode || "");
      if (!attemptCode || !sessionCode || attemptCode === sessionCode) {
        return {sessionId: sessionIdRaw, session: rtdSession};
      }
    }
    const snap = await db.collection(SESSIONS_COL).doc(sessionIdRaw).get();
    if (snap.exists) {
      const session = snap.data() || {};
      const attemptCode = normalizeSessionCode(
          data.sessionCodeRaw || data.sessionCode || "",
      );
      const sessionCode = normalizeSessionCode(session.sessionCode || "");
      if (!attemptCode || !sessionCode || attemptCode === sessionCode) {
        return {sessionId: sessionIdRaw, session};
      }
      logWarn("resolveSessionForAttempt_session_code_mismatch", {
        sessionId: sessionIdRaw,
        attemptCode,
        sessionCode,
      });
    }
  }

  const code = normalizeSessionCode(
      data.sessionCodeRaw || data.sessionCode || "",
  );
  if (!code) return null;

  /** @type {Map<string, {sessionId: string, session: Record<string, unknown>}>} */
  const entriesById = new Map();

  for (const entry of await loadRunningSessionsByCodeFromRtd(code)) {
    entriesById.set(entry.sessionId, entry);
  }

  if (entriesById.size < 16) {
    try {
      const snap = await db.collection(SESSIONS_COL)
          .where("sessionCode", "==", code)
          .limit(16)
          .get();
      for (const doc of snap.docs) {
        if (!entriesById.has(doc.id)) {
          entriesById.set(doc.id, {sessionId: doc.id, session: doc.data() || {}});
        }
      }
    } catch (e) {
      logWarn("resolveSessionForAttempt_firestore_query_failed", {code, error: String(e)});
    }
  }

  if (entriesById.size === 0) return null;

  /** @type {{sessionId: string, session: Record<string, unknown>}|null} */
  let bounded = null;
  /** @type {{sessionId: string, session: Record<string, unknown>}|null} */
  let bestActive = null;

  for (const entry of entriesById.values()) {
    const session = entry.session;

    if (isSessionOpenForCheckIn(session)) {
      if (!bestActive) {
        bestActive = entry;
      } else {
        const startA = firestoreTimestampToMillis(session.startTime) ?? 0;
        const startB = firestoreTimestampToMillis(bestActive.session.startTime) ?? 0;
        if (startA > startB) {
          bestActive = entry;
        }
      }
    }

    if (capturedAt && isTimestampWithinSessionBounds(session, capturedAt)) {
      if (!bounded) {
        bounded = entry;
      } else {
        const startA = firestoreTimestampToMillis(session.startTime) ?? 0;
        const startB = firestoreTimestampToMillis(bounded.session.startTime) ?? 0;
        if (startA > startB) {
          bounded = entry;
        }
      }
    }
  }

  return bounded || bestActive;
}

/**
 * Official absent row when session/code matched but time or GPS did not.
 * Does not downgrade an existing present row (student may retry successfully).
 * @param {FirebaseFirestore.Firestore} db
 * @param {object} opts
 * @param {string} opts.sessionId
 * @param {Record<string, unknown>} opts.session
 * @param {string} opts.studentId
 * @param {string} opts.course
 * @param {FirebaseFirestore.Timestamp|undefined} opts.capturedAt
 */
async function writeOfficialAbsentForVerifiedMismatch(
    db,
    {sessionId, session, studentId, course, capturedAt, attemptData},
) {
  if (
    attemptData &&
    checkInAttemptShouldAcceptPresent(
        attemptData,
        sessionId,
        session,
        String(session.listId || "").trim(),
    )
  ) {
    return;
  }

  const recordRef = db.collection(RECORDS_COL).doc(`${sessionId}_${studentId}`);
  const existing = await recordRef.get();
  if (existing.exists && existing.data()?.present === true) {
    return;
  }

  const endTime = session.endTime;
  const nowMs = Date.now();
  let timestamp = Timestamp.now();
  if (
    endTime &&
    typeof endTime.toMillis === "function" &&
    nowMs >= endTime.toMillis()
  ) {
    timestamp = endTime;
  } else if (
    capturedAt &&
    typeof capturedAt.toMillis === "function"
  ) {
    timestamp = capturedAt;
  }

  const absentPatch = buildOfficialAbsentRecordPatch(
      existing.exists ? existing.data() : undefined,
      {
        sessionId,
        studentId,
        course: course || "\u2014",
        timestamp,
      },
  );
  if (!absentPatch) return;
  await recordRef.set(absentPatch, {merge: true});
  await publishAttendanceRecordToRtd(db, {
    sessionId,
    studentId,
    present: false,
    verified: false,
    course: course || "\u2014",
    timestampMs: firestoreTimestampToMillis(timestamp) ?? Date.now(),
    latitude: 0,
    longitude: 0,
    recordId: `${sessionId}_${studentId}`,
    listId: String(session.listId || "").trim(),
  });
  const listId = String(session.listId || "").trim();
  if (listId) {
    await publishSessionRollStatsToRtd(db, sessionId, listId);
  }
}

/**
 * Reject still-pending attempts when a session closes (time/GPS validated).
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionId
 * @param {Record<string, unknown>} session
 */
async function reconcilePendingAttemptsForSession(db, sessionId, session) {
  await forEachQueryPage(
      db,
      db.collection(ATTEMPTS_COL)
          .where("sessionId", "==", sessionId)
          .where("status", "==", "pending"),
      async (docs) => {
        for (const doc of docs) {
          try {
            await reconcileCheckInAttempt(db, doc);
          } catch (e) {
            logError("reconcile_pending_attempt", e, {
              attemptId: doc.id,
              sessionId,
            });
          }
        }
      },
  );

  const code = normalizeSessionCode(session.sessionCode);
  if (!code) return;

  await forEachQueryPage(
      db,
      db.collection(ATTEMPTS_COL)
          .where("status", "==", "pending")
          .where("sessionCodeRaw", "==", code),
      async (docs) => {
        for (const doc of docs) {
          const d = doc.data() || {};
          if (String(d.sessionId || "").trim() === sessionId) continue;
          const attemptCode = normalizeSessionCode(
              d.sessionCodeRaw || d.sessionCode,
          );
          if (attemptCode !== code) continue;
          try {
            await reconcileCheckInAttempt(db, doc);
          } catch (e) {
            logError("reconcile_pending_attempt_by_code", e, {
              attemptId: doc.id,
              sessionId,
            });
          }
        }
      },
  );
}

/**
 * @param {string} sessionId
 * @param {string} deviceId
 * @return {string}
 */
function deviceSessionLockDocId(sessionId, deviceId) {
  const digest = crypto.createHash("sha256")
      .update(`${String(sessionId).trim()}\0${String(deviceId).trim()}`)
      .digest("hex");
  return `${String(sessionId).trim()}_${digest.slice(0, 40)}`;
}

/**
 * @param {object} opts
 * @return {Record<string, unknown>}
 */
function deviceSessionLockPayload({
  sessionId,
  listId,
  deviceId,
  studentId,
  attemptId,
  capturedAt,
  supersededStudentId,
}) {
  /** @type {Record<string, unknown>} */
  const payload = {
    sessionId: String(sessionId || "").trim(),
    deviceId: String(deviceId || "").trim(),
    studentId: String(studentId || "").trim(),
    attemptId: String(attemptId || "").trim(),
    capturedAt: capturedAt || null,
    lockedAt: FieldValue.serverTimestamp(),
  };
  const lid = String(listId || "").trim();
  if (lid) payload.listId = lid;
  const superseded = String(supersededStudentId || "").trim();
  if (superseded) payload.supersededStudentId = superseded;
  return payload;
}

/**
 * @param {FirebaseFirestore.Timestamp|Date|unknown} capturedAt
 * @return {number}
 */
function capturedAtToMillis(capturedAt) {
  if (!capturedAt) return 0;
  if (typeof capturedAt.toMillis === "function") return capturedAt.toMillis();
  if (capturedAt instanceof Date) return capturedAt.getTime();
  return 0;
}

/**
 * One present check-in per session per device. Earliest [capturedAt] wins.
 * @param {FirebaseFirestore.Firestore} db
 * @param {object} opts
 * @return {Promise<{allowed: boolean, reason?: string, supersededStudentId?: string}>}
 */
async function claimDeviceForSessionPresent(db, {
  sessionId,
  listId,
  deviceId,
  studentId,
  attemptId,
  capturedAt,
}) {
  const sid = String(sessionId || "").trim();
  const did = String(deviceId || "").trim();
  const stu = String(studentId || "").trim();
  const att = String(attemptId || "").trim();
  if (!sid || !did || !stu) {
    return {allowed: false, reason: "Missing device or session for check-in."};
  }

  const lockRef = db.collection(DEVICE_LOCKS_COL)
      .doc(deviceSessionLockDocId(sid, did));
  const attemptMs = capturedAtToMillis(capturedAt);
  /** @type {string|null} */
  let supersededStudentId = null;

  const allowed = await db.runTransaction(async (tx) => {
    const lockSnap = await tx.get(lockRef);
    if (!lockSnap.exists) {
      tx.set(lockRef, deviceSessionLockPayload({
        sessionId: sid,
        listId,
        deviceId: did,
        studentId: stu,
        attemptId: att,
        capturedAt,
      }));
      return true;
    }

    const lock = lockSnap.data() || {};
    const winner = String(lock.studentId || "").trim();
    if (winner === stu) return true;

    const winnerMs = capturedAtToMillis(lock.capturedAt);
    if (attemptMs > 0 && (winnerMs === 0 || attemptMs < winnerMs)) {
      supersededStudentId = winner;
      tx.set(lockRef, deviceSessionLockPayload({
        sessionId: sid,
        listId: listId || lock.listId,
        deviceId: did,
        studentId: stu,
        attemptId: att,
        capturedAt,
        supersededStudentId: winner,
      }));
      return true;
    }

    return false;
  });

  if (!allowed) {
    return {
      allowed: false,
      reason: "Device already used for another student this session.",
    };
  }
  return {
    allowed: true,
    supersededStudentId: supersededStudentId || undefined,
  };
}

/**
 * Removes a superseded present row when an earlier check-in claims the device.
 * @param {FirebaseFirestore.Firestore} db
 * @param {object} opts
 */
async function revokeDeviceSupersededCheckIn(db, {
  sessionId,
  supersededStudentId,
  reason,
}) {
  const sid = String(sessionId || "").trim();
  const other = String(supersededStudentId || "").trim();
  if (!sid || !other) return;

  const recordRef = db.collection(RECORDS_COL).doc(`${sid}_${other}`);
  const recordSnap = await recordRef.get();
  if (recordSnap.exists && recordSnap.data()?.present === true) {
    await recordRef.set({
      present: false,
      verified: true,
      deviceSuperseded: true,
      revocationReason: reason ||
        "Device claimed by an earlier check-in on this session.",
      serverReceivedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
  }

  const attemptRef = db.collection(ATTEMPTS_COL).doc(`${sid}_${other}`);
  const attemptSnap = await attemptRef.get();
  if (attemptSnap.exists) {
    const st = String(attemptSnap.data()?.status || "").trim().toLowerCase();
    if (st === "pending" || st === "accepted") {
      await attemptRef.update({
        status: "rejected",
        rejectionReason: reason ||
          "Device claimed by an earlier check-in on this session.",
        processedAt: FieldValue.serverTimestamp(),
      });
    }
  }
}

/**
 * True when the same device already has a pending/accepted claim or attempt
 * for another student on the same session code or session id.
 * @param {FirebaseFirestore.Firestore} db
 * @param {FirebaseFirestore.DocumentSnapshot} attemptSnap
 * @param {Record<string, unknown>} data
 * @return {Promise<boolean>}
 */
async function deviceUsedByOtherStudentOnClaim(db, attemptSnap, data) {
  const deviceId = String(data.deviceId || "").trim();
  const studentId = String(data.studentId || "").trim();
  if (!deviceId || !studentId) return false;

  const code = normalizeSessionCode(
      data.sessionCodeRaw || data.sessionCode || "",
  );
  if (code) {
    const dupByCode = await db
        .collection(ATTEMPTS_COL)
        .where("deviceId", "==", deviceId)
        .where("sessionCodeRaw", "==", code)
        .where("status", "in", ["pending", "accepted"])
        .limit(12)
        .get();
    for (const doc of dupByCode.docs) {
      if (doc.id === attemptSnap.id) continue;
      const other = String(doc.data().studentId || "").trim();
      if (other && other !== studentId) return true;
    }
  }

  const sessionId = String(data.sessionId || "").trim();
  if (sessionId) {
    const dupBySession = await db
        .collection(ATTEMPTS_COL)
        .where("deviceId", "==", deviceId)
        .where("sessionId", "==", sessionId)
        .where("status", "in", ["pending", "accepted"])
        .limit(12)
        .get();
    for (const doc of dupBySession.docs) {
      if (doc.id === attemptSnap.id) continue;
      const other = String(doc.data().studentId || "").trim();
      if (other && other !== studentId) return true;
    }

    const presentSnap = await db
        .collection(RECORDS_COL)
        .where("sessionId", "==", sessionId)
        .where("present", "==", true)
        .get();
    for (const doc of presentSnap.docs) {
      const row = doc.data() || {};
      const otherDevice = String(row.deviceId || "").trim();
      const otherStudent = String(row.studentId || "").trim();
      if (otherDevice === deviceId &&
          otherStudent &&
          otherStudent !== studentId) {
        return true;
      }
    }
  }
  return false;
}

/**
 * @param {unknown} v
 * @returns {number|null}
 */
function sessionTimestampToMs(v) {
  if (!v) return null;
  if (typeof v.toMillis === "function") return v.toMillis();
  if (v instanceof Date) return v.getTime();
  if (typeof v === "number" && Number.isFinite(v)) return v;
  return null;
}

/**
 * @param {string} sessionId
 * @param {Record<string, unknown>} session
 * @returns {Record<string, unknown>}
 */
function buildSessionRtdPayload(sessionId, session) {
  const code = normalizeSessionCode(session.sessionCode);
  const startMs = sessionTimestampToMs(session.startTime);
  const endMs = sessionTimestampToMs(session.endTime);
  const status = String(session.status || "active").trim().toLowerCase();
  const createdByUid = String(session.createdByUid || "").trim();
  const lecturerUid = String(session.lecturerUid || "").trim();
  /** @type {Record<string, unknown>} */
  const payload = {
    id: sessionId,
    listId: String(session.listId || "").trim(),
    sessionCode: code || String(session.sessionCode || "").trim(),
    latitude: Number(session.latitude) || 0,
    longitude: Number(session.longitude) || 0,
    radiusMeters: Number(session.radiusMeters) || 50,
    startTime: startMs ?? Date.now(),
    endTime: endMs ?? Date.now(),
    status: status === "closed" ? "closed" : "active",
    createdBy: String(session.createdBy || "").trim(),
    remoteLearning: session.remoteLearning === true,
    updatedAt: Date.now(),
  };
  if (createdByUid) payload.createdByUid = createdByUid;
  if (lecturerUid) payload.lecturerUid = lecturerUid;
  if (session.locationMetadataPending === true) {
    payload.locationMetadataPending = true;
  }
  return payload;
}

/**
 * @param {unknown} v
 * @returns {boolean}
 */
function isTruthyFlag(v) {
  return v === true || v === "true" || v === 1;
}

/**
 * Mirrors staff role flags to RTDB for security rules (admins + lecturers).
 * @param {string} uid
 * @param {{isAdmin?: boolean, isLecturer?: boolean}} flags
 */
async function publishStaffAccessToRtd(uid, flags = {}) {
  const id = String(uid || "").trim();
  if (!id) return;
  /** @type {Record<string, unknown>} */
  const payload = {
    isAdmin: flags.isAdmin === true,
    isLecturer: flags.isLecturer === true,
    updatedAt: Date.now(),
  };
  try {
    await admin.database().ref(`${RTD_STAFF_ACCESS}/${id}`).set(payload);
  } catch (e) {
    logError("publish_staff_access_rtd", e, {uid: id});
  }
}

/**
 * @param {string} uid
 */
async function removeStaffAccessFromRtd(uid) {
  const id = String(uid || "").trim();
  if (!id) return;
  try {
    await admin.database().ref(`${RTD_STAFF_ACCESS}/${id}`).set(null);
  } catch (e) {
    logError("remove_staff_access_rtd", e, {uid: id});
  }
}

/**
 * @param {Record<string, unknown>} session
 * @returns {Promise<Record<string, unknown>>}
 */
async function enrichSessionForRtd(session) {
  /** @type {Record<string, unknown>} */
  const enriched = {...(session || {})};
  const listId = String(enriched.listId || "").trim();
  if (!listId) return enriched;
  if (String(enriched.lecturerUid || "").trim()) return enriched;
  try {
    const listSnap = await upanelDb().collection("attendance_lists").doc(listId).get();
    if (listSnap.exists) {
      const lecturerUid = String(listSnap.data()?.lecturerUid || "").trim();
      if (lecturerUid) enriched.lecturerUid = lecturerUid;
    }
  } catch (e) {
    logError("enrich_session_for_rtd", e, {listId});
  }
  return enriched;
}

/**
 * Mirrors an attendance session to Realtime Database for fast join-code discovery.
 * @param {string} sessionId
 * @param {Record<string, unknown>} session
 * @param {{remove?: boolean}} [opts]
 */
async function publishSessionToRtd(sessionId, session, opts = {}) {
  const sid = String(sessionId || "").trim();
  if (!sid) return;
  const remove = opts.remove === true;
  const enriched = await enrichSessionForRtd(session || {});
  const code = normalizeSessionCode(enriched.sessionCode);
  const listId = String(enriched.listId || "").trim();
  const status = String(enriched.status || "active").trim().toLowerCase();

  /** @type {Record<string, unknown>} */
  const updates = {};

  if (remove) {
    updates[`${RTD_ATTENDANCE_SESSIONS}/by_id/${sid}`] = null;
    if (code) {
      updates[`${RTD_ATTENDANCE_SESSIONS}/by_code/${code}/${sid}`] = null;
    }
    if (listId) {
      updates[`${RTD_ATTENDANCE_SESSIONS}/by_list/${listId}/${sid}`] = null;
    }
  } else if (status === "closed") {
    const payload = buildSessionRtdPayload(sid, enriched);
    updates[`${RTD_ATTENDANCE_SESSIONS}/by_id/${sid}`] = payload;
    if (code) {
      updates[`${RTD_ATTENDANCE_SESSIONS}/by_code/${code}/${sid}`] = null;
    }
    if (listId) {
      updates[`${RTD_ATTENDANCE_SESSIONS}/by_list/${listId}/${sid}`] = payload;
    }
  } else {
    const payload = buildSessionRtdPayload(sid, enriched);
    updates[`${RTD_ATTENDANCE_SESSIONS}/by_id/${sid}`] = payload;
    if (code) {
      updates[`${RTD_ATTENDANCE_SESSIONS}/by_code/${code}/${sid}`] = payload;
    }
    if (listId) {
      updates[`${RTD_ATTENDANCE_SESSIONS}/by_list/${listId}/${sid}`] = payload;
    }
  }

  try {
    await admin.database().ref().update(updates);
  } catch (e) {
    logError("publish_session_rtd", e, {sessionId: sid, remove});
  }
}

/**
 * Publishes check-in outcome to Realtime Database for low-latency client confirmation.
 * @param {object} params
 * @param {string} params.sessionId
 * @param {string} params.studentId
 * @param {string} params.status accepted|rejected
 * @param {boolean} [params.present]
 * @param {boolean} [params.verified]
 * @param {string} [params.rejectionReason]
 * @param {string} [params.recordId]
 */
async function publishCheckInConfirmationToRtd({
  sessionId,
  studentId,
  status,
  present = false,
  verified = false,
  rejectionReason,
  recordId,
}) {
  const sid = String(sessionId || "").trim();
  const stu = String(studentId || "").trim();
  const st = String(status || "").trim().toLowerCase();
  if (!stu || !st) return;

  /** @type {Record<string, unknown>} */
  const payload = {
    status: st,
    studentId: stu,
    present: !!present,
    verified: !!verified,
    updatedAt: Date.now(),
  };
  if (sid) payload.sessionId = sid;
  const reason = String(rejectionReason || "").trim();
  if (reason) payload.rejectionReason = reason;

  const rid = String(recordId || "").trim() ||
    (sid ? `${sid}_${stu}` : "");
  /** @type {Record<string, unknown>} */
  const updates = {};
  if (sid) {
    updates[
        `${RTD_CHECK_IN_CONFIRMATIONS}/by_student/${stu}/${sid}`] = payload;
    updates[
        `${RTD_CHECK_IN_CONFIRMATIONS}/by_session/${sid}/${stu}`] = payload;
  }
  if (rid) {
    updates[`${RTD_CHECK_IN_CONFIRMATIONS}/by_record/${rid}`] = payload;
  }
  if (Object.keys(updates).length === 0) return;

  try {
    await admin.database().ref().update(updates);
  } catch (e) {
    logError("publish_check_in_rtd", e, {sessionId: sid, studentId: stu, status: st});
  }
}

/**
 * @param {object} opts
 * @return {Record<string, unknown>|null}
 */
function buildAttendanceRecordRtdPayload({
  sessionId,
  studentId,
  present,
  verified,
  course,
  timestampMs,
  latitude,
  longitude,
  deviceId,
  recordId,
}) {
  const sid = String(sessionId || "").trim();
  const stu = String(studentId || "").trim();
  if (!sid || !stu) return null;
  const rid = String(recordId || "").trim() || `${sid}_${stu}`;
  const now = Date.now();
  const ts = Number.isFinite(timestampMs) && timestampMs > 0 ?
    timestampMs :
    now;
  /** @type {Record<string, unknown>} */
  const payload = {
    recordId: rid,
    sessionId: sid,
    studentId: stu,
    present: !!present,
    verified: !!verified,
    course: String(course || "").trim() || "\u2014",
    timestamp: ts,
    latitude: Number(latitude) || 0,
    longitude: Number(longitude) || 0,
    updatedAt: now,
  };
  const dev = String(deviceId || "").trim();
  if (dev) payload.deviceId = dev;
  return payload;
}

/**
 * Student attendance % for one list (mirrors client rollStatsForRegistrationOnList).
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} studentId
 * @param {string} listId
 * @return {Promise<Record<string, unknown>>}
 */
async function computeStudentListRollStats(db, studentId, listId) {
  const stu = String(studentId || "").trim();
  const lid = String(listId || "").trim();
  const nowMs = Date.now();
  if (!stu || !lid) {
    return {
      studentId: stu,
      listId: lid,
      present: 0,
      total: 0,
      percentRounded: 0,
      updatedAt: nowMs,
    };
  }

  const {earliestSignedInByStudent} = await loadSignInRosterForList(db, lid);
  const signedInAt = earliestSignedInByStudent.get(stu);
  const signedMs =
    signedInAt && typeof signedInAt.toMillis === "function" ?
      signedInAt.toMillis() :
      0;

  const sessSnap = await db.collection(SESSIONS_COL)
      .where("listId", "==", lid)
      .get();

  let present = 0;
  let total = 0;
  /** @type {Set<string>} */
  const countedSessionIds = new Set();

  for (const doc of sessSnap.docs) {
    const s = doc.data() || {};
    if (!sessionCountsTowardRollStats(s, nowMs)) continue;
    const endMs = firestoreTimestampToMillis(s.endTime) ?? 0;
    const missedBeforeJoin = signedMs > 0 && endMs > 0 && endMs < signedMs;
    const recSnap = await db.collection(RECORDS_COL).doc(`${doc.id}_${stu}`).get();
    if (recSnap.exists) {
      total++;
      if (recSnap.data()?.present === true) present++;
      countedSessionIds.add(doc.id);
      continue;
    }
    if (!missedBeforeJoin) {
      const graceExpired = await studentSessionGraceExpired(
          db, lid, stu, endMs, signedInAt, nowMs);
      if (!graceExpired) continue;
    }
    total++;
    countedSessionIds.add(doc.id);
  }

  for (const doc of sessSnap.docs) {
    if (countedSessionIds.has(doc.id)) continue;
    const s = doc.data() || {};
    if (!sessionCountsTowardRollStats(s, nowMs)) continue;
    const recSnap = await db.collection(RECORDS_COL).doc(`${doc.id}_${stu}`).get();
    if (!recSnap.exists) continue;
    total++;
    if (recSnap.data()?.present === true) present++;
    countedSessionIds.add(doc.id);
  }

  const percentRounded = total <= 0 ?
    0 :
    Math.round((100 * present) / total);
  return {
    studentId: stu,
    listId: lid,
    present,
    total,
    percentRounded,
    updatedAt: nowMs,
  };
}

/**
 * Overall student attendance % across all signed-in lists.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} studentId
 * @return {Promise<Record<string, unknown>>}
 */
async function computeStudentOverallRollStats(db, studentId) {
  const stu = String(studentId || "").trim();
  const nowMs = Date.now();
  if (!stu) {
    return {studentId: "", present: 0, total: 0, percentRounded: 0, updatedAt: nowMs};
  }
  const signSnap = await db.collection("sign_ins")
      .where("studentId", "==", stu)
      .get();
  /** @type {Set<string>} */
  const listIds = new Set();
  for (const doc of signSnap.docs) {
    const lid = String(doc.data()?.listId || "").trim();
    if (lid) listIds.add(lid);
  }
  let present = 0;
  let total = 0;
  for (const lid of listIds) {
    const stats = await computeStudentListRollStats(db, stu, lid);
    present += Number(stats.present) || 0;
    total += Number(stats.total) || 0;
  }
  const percentRounded = total <= 0 ?
    0 :
    Math.round((100 * present) / total);
  return {
    studentId: stu,
    present,
    total,
    percentRounded,
    updatedAt: nowMs,
  };
}

/**
 * Maps Auth uid → registration so RTD rules authorize by_student reads.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} studentId registration number (canonical studentId in records)
 */
async function publishStudentRtdIndexToRtd(db, studentId) {
  const stu = String(studentId || "").trim();
  if (!stu || !db) return;
  try {
    const regSnap = await db.collection("student_registrations").doc(stu).get();
    if (!regSnap.exists) return;
    const uid = String(regSnap.data()?.uid || "").trim();
    if (!uid) return;
    await admin.database().ref().update({
      [`${RTD_STUDENT_RTD_INDEX}/${uid}`]: stu,
    });
  } catch (e) {
    logError("publish_student_rtd_index", e, {studentId: stu});
  }
}

/**
 * Publishes student roll stats for instant profile/dashboard refresh.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} studentId
 * @param {string|null|undefined} listId
 */
async function publishStudentRollStatsToRtd(db, studentId, listId) {
  const stu = String(studentId || "").trim();
  if (!stu) return;
  try {
    /** @type {Record<string, unknown>} */
    const updates = {};
    const lid = String(listId || "").trim();
    if (lid) {
      const listStats = await computeStudentListRollStats(db, stu, lid);
      updates[`${RTD_ATTENDANCE_ROLL_STATS}/by_student/${stu}/by_list/${lid}`] =
        listStats;
    }
    const overall = await computeStudentOverallRollStats(db, stu);
    updates[`${RTD_ATTENDANCE_ROLL_STATS}/by_student/${stu}`] = overall;
    await admin.database().ref().update(updates);
    await publishStudentRtdIndexToRtd(db, stu);
  } catch (e) {
    logError("publish_student_roll_stats_rtd", e, {studentId: stu, listId});
  }
}

/**
 * Mirrors one official attendance row to Realtime Database.
 * @param {FirebaseFirestore.Firestore|null|undefined} db
 * @param {object} opts
 */
async function publishAttendanceRecordToRtd(db, opts) {
  const payload = buildAttendanceRecordRtdPayload(opts);
  if (!payload) return;
  const sid = String(payload.sessionId || "").trim();
  const stu = String(payload.studentId || "").trim();
  /** @type {Record<string, unknown>} */
  const updates = {};
  updates[`${RTD_ATTENDANCE_RECORDS}/by_session/${sid}/${stu}`] = payload;
  updates[`${RTD_ATTENDANCE_RECORDS}/by_student/${stu}/${sid}`] = payload;
  try {
    await admin.database().ref().update(updates);
  } catch (e) {
    logError("publish_attendance_record_rtd", e, {sessionId: sid, studentId: stu});
    return;
  }
  if (db && stu) {
    let listId = String(opts.listId || "").trim();
    if (!listId && sid) {
      listId = await resolveListIdForSessionId(db, sid);
    }
    await publishStudentRollStatsToRtd(db, stu, listId || undefined);
  }
}

/**
 * @param {FirebaseFirestore.Firestore|null|undefined} db
 * @param {object[]} records
 */
async function publishAttendanceRecordBatchToRtd(db, records) {
  if (!records.length) return;
  /** @type {Record<string, unknown>} */
  const updates = {};
  /** @type {Set<string>} */
  const studentIds = new Set();
  /** @type {Map<string, string>} */
  const listIdByStudent = new Map();
  for (const opts of records) {
    const payload = buildAttendanceRecordRtdPayload(opts);
    if (!payload) continue;
    const sid = String(payload.sessionId || "").trim();
    const stu = String(payload.studentId || "").trim();
    if (stu) {
      studentIds.add(stu);
      const lid = String(opts.listId || "").trim();
      if (lid) listIdByStudent.set(stu, lid);
    }
    updates[`${RTD_ATTENDANCE_RECORDS}/by_session/${sid}/${stu}`] = payload;
    updates[`${RTD_ATTENDANCE_RECORDS}/by_student/${stu}/${sid}`] = payload;
  }
  if (Object.keys(updates).length === 0) return;
  try {
    await admin.database().ref().update(updates);
  } catch (e) {
    logError("publish_attendance_record_batch_rtd", e, {count: records.length});
    return;
  }
  if (db) {
    for (const stu of studentIds) {
      await publishStudentRollStatsToRtd(db, stu, listIdByStudent.get(stu));
    }
  }
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionId
 * @param {string} listId
 * @return {Promise<Record<string, unknown>>}
 */
async function computeSessionRollStats(db, sessionId, listId) {
  const sid = String(sessionId || "").trim();
  const recSnap = await db.collection(RECORDS_COL)
      .where("sessionId", "==", sid)
      .get();
  let present = 0;
  let absent = 0;
  /** @type {Set<string>} */
  const withRecord = new Set();
  for (const doc of recSnap.docs) {
    const d = doc.data() || {};
    const stu = String(d.studentId || "").trim();
    if (stu) withRecord.add(stu);
    if (d.present === true) present++;
    else absent++;
  }
  const {courseByStudent} = await loadSignInRosterForList(
      db,
      String(listId || "").trim(),
  );
  /** @type {Set<string>} */
  const enrolledSet = new Set(courseByStudent.keys());
  for (const stu of withRecord) enrolledSet.add(stu);
  const enrolled = enrolledSet.size;
  const pending = Math.max(0, enrolled - present - absent);
  const resolved = present + absent;
  const percentRounded = resolved <= 0 ?
    0 :
    Math.round((100 * present) / resolved);
  return {
    sessionId: sid,
    listId: String(listId || "").trim(),
    enrolled,
    present,
    absent,
    pending,
    percentRounded,
    updatedAt: Date.now(),
  };
}

/**
 * Publishes present/absent/pending counts for instant roll UI refresh.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionId
 * @param {string} listId
 */
async function publishSessionRollStatsToRtd(db, sessionId, listId) {
  const sid = String(sessionId || "").trim();
  if (!sid) return;
  const lid = String(listId || "").trim();
  try {
    const stats = await computeSessionRollStats(db, sid, lid);
    /** @type {Record<string, unknown>} */
    const updates = {
      [`${RTD_ATTENDANCE_ROLL_STATS}/by_session/${sid}`]: stats,
    };
    if (lid) {
      updates[`${RTD_ATTENDANCE_ROLL_STATS}/by_list/${lid}/${sid}`] = stats;
    }
    await admin.database().ref().update(updates);
  } catch (e) {
    logError("publish_roll_stats_rtd", e, {sessionId: sid, listId: lid});
  }
}

/**
 * Validates a pending check-in attempt and writes the official attendance row.
 * @param {FirebaseFirestore.Firestore} db
 * @param {FirebaseFirestore.DocumentSnapshot} attemptSnap
 */
async function reconcileCheckInAttempt(db, attemptSnap) {
  const data = attemptSnap.data() || {};
  if (data.status !== "pending") return;

  const studentId = String(data.studentId || "").trim();
  const listId = String(data.listId || "").trim();
  const course = String(data.course || "").trim() || "\u2014";
  const deviceId = String(data.deviceId || "").trim();
  const capturedAt = data.capturedAt;
  const latitude = Number(data.latitude);
  const longitude = Number(data.longitude);

  /** @param {string} reason @param {string} resolvedSessionId @param {boolean} markAbsent @param {Record<string, unknown>|null} [sessionForLog] */
  async function reject(reason, resolvedSessionId, markAbsent = false, sessionForLog = null) {
    /** @type {Record<string, unknown>} */
    const patch = {
      status: "rejected",
      rejectionReason: reason,
      processedAt: FieldValue.serverTimestamp(),
    };
    if (resolvedSessionId) {
      patch.sessionId = resolvedSessionId;
    }
    await attemptSnap.ref.update(patch);
    await publishCheckInConfirmationToRtd({
      sessionId: resolvedSessionId,
      studentId,
      status: "rejected",
      present: false,
      verified: false,
      rejectionReason: reason,
      recordId: attemptSnap.id,
    });
    if (markAbsent && resolvedSessionId && sessionForLog) {
      await writeOfficialAbsentForVerifiedMismatch(db, {
        sessionId: resolvedSessionId,
        session: sessionForLog,
        studentId,
        course,
        capturedAt,
        attemptData: data,
      });
    }
  }

  if (!studentId || !capturedAt) {
    await reject("Missing session, student, or capture time.", "");
    return;
  }

  if (!deviceId) {
    await reject("Missing device id for check-in.", "");
    return;
  }

  if (await deviceUsedByOtherStudentOnClaim(db, attemptSnap, data)) {
    await reject(
        "Device already used for another student this session.",
        String(data.sessionId || "").trim(),
    );
    return;
  }

  if (!hasCompleteStudentAttemptMetadata(data)) {
    if (!attemptRetentionExpired(data)) return;
    await reject("Missing student check-in metadata.", "");
    return;
  }

  const hintedSessionId = String(data.sessionId || "").trim();
  if (hintedSessionId && data.awaitingSession !== true) {
    const rtdHint = await loadRunningSessionFromRtd(hintedSessionId);
    const hintSnap = rtdHint ?
      null :
      await db.collection(SESSIONS_COL).doc(hintedSessionId).get();
    if (!rtdHint && !hintSnap?.exists) {
      if (!attemptRetentionExpired(data)) return;
      await reject(
          "Lecturer session metadata not found within the retention window.",
          "",
          false,
      );
      return;
    }
  }

  const resolved = await resolveSessionForAttempt(db, data);
  if (!resolved) {
    if (attemptRetentionExpired(data)) {
      await reject(
          "Session code not found within the retention window.",
          "",
          false,
      );
    }
    return;
  }

  const sessionId = resolved.sessionId;
  const session = resolved.session;

  if (await deviceUsedByOtherStudentOnClaim(db, attemptSnap, {
    ...data,
    sessionId,
  })) {
    await reject(
        "Device already used for another student this session.",
        sessionId,
    );
    return;
  }

  if (data.awaitingSession === true) {
    await attemptSnap.ref.update({
      sessionId,
      listId: String(session.listId || listId || "").trim(),
      awaitingSession: false,
    });
  }

  if (listId && String(session.listId || "").trim() !== listId) {
    const attemptCode = normalizeSessionCode(String(data.sessionCodeRaw || ""));
    const sessionCode = normalizeSessionCode(String(session.sessionCode || ""));
    if (!attemptCode || attemptCode !== sessionCode) {
      await reject("Session does not match list.", sessionId, false, session);
      return;
    }
  }

  const resolvedListId = String(session.listId || listId || "").trim();
  if (!checkInAttemptShouldAcceptPresent(
      data,
      sessionId,
      session,
      resolvedListId,
  )) {
    await reject(
        "Check-in does not match session metadata.",
        sessionId,
        false,
        session,
    );
    return;
  }

  const recordRef = db.collection(RECORDS_COL).doc(`${sessionId}_${studentId}`);
  const existingRecord = await recordRef.get();
  if (existingRecord.exists && existingRecord.data()?.present === true) {
    await attemptSnap.ref.update({
      status: "accepted",
      sessionId,
      note: "Already present on official roll.",
      processedAt: FieldValue.serverTimestamp(),
    });
    await publishCheckInConfirmationToRtd({
      sessionId,
      studentId,
      status: "accepted",
      present: true,
      verified: true,
      recordId: attemptSnap.id,
    });
    return;
  }

  const claim = await claimDeviceForSessionPresent(db, {
    sessionId,
    listId: resolvedListId,
    deviceId,
    studentId,
    attemptId: attemptSnap.id,
    capturedAt,
  });
  if (!claim.allowed) {
    await reject(
        claim.reason ||
        "Device already used for another student this session.",
        sessionId,
        false,
        session,
    );
    return;
  }
  if (claim.supersededStudentId) {
    await revokeDeviceSupersededCheckIn(db, {
      sessionId,
      supersededStudentId: claim.supersededStudentId,
      reason: "Device claimed by an earlier check-in on this session.",
    });
  }

  // Session time + GPS already validated; roster sign-in is not required to mark
  // present (supports offline check-ins that sync after class list enrollment).

  const presentPatch = buildOfficialPresentRecordPatch(
      existingRecord.exists ? existingRecord.data() : undefined,
      {
        sessionId,
        studentId,
        course,
        capturedAt,
        latitude,
        longitude,
        deviceId,
        metadataMatchedPresent: false,
      },
  );
  if (presentPatch) {
    await recordRef.set(presentPatch, {merge: true});
  }

  await attemptSnap.ref.update({
    status: "accepted",
    sessionId,
    processedAt: FieldValue.serverTimestamp(),
  });
  await publishCheckInConfirmationToRtd({
    sessionId,
    studentId,
    status: "accepted",
    present: true,
    verified: true,
    recordId: attemptSnap.id,
  });
  await publishAttendanceRecordToRtd(db, {
    sessionId,
    studentId,
    present: true,
    verified: true,
    course,
    timestampMs: firestoreTimestampToMillis(capturedAt) ?? Date.now(),
    latitude,
    longitude,
    deviceId,
    recordId: `${sessionId}_${studentId}`,
    listId: resolvedListId,
  });
  if (resolvedListId) {
    await publishSessionRollStatsToRtd(db, sessionId, resolvedListId);
  }

  try {
    await db.collection(SESSIONS_COL).doc(sessionId).update({
      awaitingStudentMetadata: false,
    });
  } catch (_) {}
}

/**
 * Writes official absent rows for sessions on [listId] the student missed.
 * Sessions that ended before [signedInAt] are backfilled immediately; others
 * follow the normal grace / finalized rules.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} listId
 * @param {string} studentId
 * @param {string} course
 * @param {FirebaseFirestore.Timestamp|undefined} signedInAt
 */
async function upgradeMetadataMatchedAbsentRecordsForStudentOnList(
    db,
    listId,
    studentId,
) {
  let corrected = 0;

  const tryUpgrade = async (sessionId, session, attemptSnap) => {
    const recordRef = db.collection(RECORDS_COL).doc(`${sessionId}_${studentId}`);
    const existing = await recordRef.get();
    if (existing.exists && existing.data()?.present === true) return;
    const ad = attemptSnap.data() || {};
    const st = String(ad.status || "").trim().toLowerCase();
    if (checkInAttemptShouldAcceptPresent(ad, sessionId, session, listId)) {
      await writePresentFromMetadataAttempt(
          db,
          sessionId,
          session,
          attemptSnap,
      );
      if (String(ad.status || "").trim().toLowerCase() === "pending") {
        try {
          await reconcileCheckInAttempt(db, attemptSnap);
        } catch (e) {
          logError("upgrade_reconcile_pending", e, {sessionId, studentId});
        }
      }
      corrected++;
    } else if (String(ad.status || "").trim().toLowerCase() === "accepted") {
      await writePresentFromMetadataAttempt(
          db,
          sessionId,
          session,
          attemptSnap,
      );
      corrected++;
    }
  };

  await forEachQueryPage(
      db,
      db.collection(RECORDS_COL).where("studentId", "==", studentId),
      async (docs) => {
        for (const doc of docs) {
          const d = doc.data() || {};
          if (d.present === true) continue;
          const sessionId = String(d.sessionId || "").trim();
          if (!sessionId) continue;
          const sessSnap = await db.collection(SESSIONS_COL).doc(sessionId).get();
          if (!sessSnap.exists) continue;
          const s = sessSnap.data() || {};
          if (String(s.listId || "").trim() !== listId) continue;
          const attemptSnap = await findMetadataMatchedAttemptSnap(
              db,
              sessionId,
              s,
              listId,
              studentId,
          );
          if (!attemptSnap) continue;
          await tryUpgrade(sessionId, s, attemptSnap);
        }
      },
  );

  await forEachQueryPage(
      db,
      db.collection(ATTEMPTS_COL).where("studentId", "==", studentId),
      async (docs) => {
        for (const doc of docs) {
          const d = doc.data() || {};
          let sessionId = String(d.sessionId || "").trim();
          let session = null;
          if (sessionId) {
            const sessSnap = await db.collection(SESSIONS_COL).doc(sessionId).get();
            if (!sessSnap.exists) continue;
            session = sessSnap.data() || {};
            if (String(session.listId || "").trim() !== listId) continue;
          } else {
            const resolved = await resolveSessionForAttempt(db, d);
            if (!resolved) continue;
            sessionId = resolved.sessionId;
            session = resolved.session;
            if (String(session.listId || "").trim() !== listId) continue;
          }
          await tryUpgrade(sessionId, session, doc);
        }
      },
  );

  if (corrected > 0) {
    logInfo("upgrade_metadata_absent_to_present", {listId, studentId, corrected});
  }
}

async function backfillAbsentRecordsForStudentOnList(
    db,
    listId,
    studentId,
    course,
    signedInAt,
) {
  await upgradeMetadataMatchedAbsentRecordsForStudentOnList(
      db,
      listId,
      studentId,
  );

  const now = Timestamp.now();
  const nowMs = now.toMillis();
  const signedMs =
    signedInAt && typeof signedInAt.toMillis === "function" ?
      signedInAt.toMillis() :
      nowMs;
  const graceCutoff = Timestamp.fromMillis(nowMs - GRACE_MS);

  let batch = db.batch();
  let n = 0;
  let written = 0;

  /**
   * @param {FirebaseFirestore.QueryDocumentSnapshot[]} docs
   */
  const processSessionDocs = async (docs) => {
    for (const doc of docs) {
      const s = doc.data() || {};
      const endTime = s.endTime;
      const endMs = firestoreTimestampToMillis(endTime);
      if (endMs == null) continue;

      const stillOpen =
        endMs > nowMs &&
        s.status !== "closed" &&
        s.finalized !== true;
      if (stillOpen) continue;

      const missedBeforeJoin = signedMs > 0 && endMs < signedMs;
      const graceExpired = await studentSessionGraceExpired(
          db, listId, studentId, endMs, signedInAt, nowMs);
      if (!missedBeforeJoin && !graceExpired && s.finalized !== true) {
        continue;
      }

      const sessionId = doc.id;
      const recordRef = db.collection(RECORDS_COL)
          .doc(`${sessionId}_${studentId}`);
      const existing = await recordRef.get();
      if (existing.exists && existing.data()?.present === true) continue;

      const pendingSnap = await findMetadataMatchedAttemptSnap(
          db,
          sessionId,
          s,
          listId,
          studentId,
      );
      if (pendingSnap) {
        const ad = pendingSnap.data() || {};
        const st = String(ad.status || "").trim().toLowerCase();
        if (
          st === "accepted" ||
          checkInAttemptShouldAcceptPresent(ad, sessionId, s, listId)
        ) {
          await writePresentFromMetadataAttempt(
              db,
              sessionId,
              s,
              pendingSnap,
          );
          continue;
        }
        if (studentAttemptMissingMetadataForPending(ad) &&
            !attemptRetentionExpired(ad)) {
          continue;
        }
      }

      if (await shouldDeferAbsentForIncompleteMetadata(
          db,
          sessionId,
          s,
          listId,
          studentId,
      )) {
        continue;
      }

      const absentPatch = buildOfficialAbsentRecordPatch(
          existing.exists ? existing.data() : undefined,
          {
            sessionId,
            studentId,
            course: course || "\u2014",
            timestamp: endTime,
          },
      );
      if (!absentPatch) continue;

      batch.set(recordRef, absentPatch, {merge: true});
      n++;
      written++;
      if (n >= BATCH_WRITE_LIMIT) {
        await batch.commit();
        batch = db.batch();
        n = 0;
      }
    }
  };

  // Ended within the grace window (or finalized) — avoids scanning very old sessions.
  await forEachQueryPage(
      db,
      db.collection(SESSIONS_COL)
          .where("listId", "==", listId)
          .where("endTime", "<=", now)
          .where("endTime", ">=", graceCutoff),
      processSessionDocs,
  );

  // Sessions that ended before the student joined the list (retroactive absent).
  if (signedInAt && typeof signedInAt.toMillis === "function") {
    await forEachQueryPage(
        db,
        db.collection(SESSIONS_COL)
            .where("listId", "==", listId)
            .where("endTime", "<", signedInAt),
        processSessionDocs,
    );
  }

  if (n > 0) {
    await batch.commit();
  }
  if (written > 0) {
    logInfo("backfill_absents_for_student", {listId, studentId, written});
  }
}

/**
 * Deletes documents returned by [query] in batches of 400.
 * @param {FirebaseFirestore.Firestore} db
 * @param {FirebaseFirestore.Query} query
 * @returns {Promise<number>} total documents deleted
 */
async function deleteQueryInBatches(db, query) {
  let total = 0;
  for (;;) {
    const snap = await query.limit(BATCH_WRITE_LIMIT).get();
    if (snap.empty) break;
    const batch = db.batch();
    for (const doc of snap.docs) {
      batch.delete(doc.ref);
    }
    await batch.commit();
    total += snap.size;
    if (snap.size < BATCH_WRITE_LIMIT) break;
  }
  return total;
}

/**
 * Applies a multi-path Realtime Database update, chunking when needed.
 * @param {Record<string, unknown>} updates
 */
async function applyRtdUpdates(updates) {
  const keys = Object.keys(updates);
  if (keys.length === 0) return;
  for (let i = 0; i < keys.length; i += BATCH_WRITE_LIMIT) {
    /** @type {Record<string, unknown>} */
    const chunk = {};
    for (const key of keys.slice(i, i + BATCH_WRITE_LIMIT)) {
      chunk[key] = updates[key];
    }
    try {
      await admin.database().ref().update(chunk);
    } catch (e) {
      logError("apply_rtd_updates", e, {count: Object.keys(chunk).length});
    }
  }
}

/**
 * Collects session ids (and optional join codes) tied to a list. Includes
 * sessions still in Firestore and ids discovered from records/attempts when
 * the client removed session docs before the list document.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} listId
 * @returns {Promise<Map<string, {sessionCode?: string}>>}
 */
async function collectSessionsForListDelete(db, listId) {
  /** @type {Map<string, {sessionCode?: string}>} */
  const sessions = new Map();

  const addSession = (sessionId, data = {}) => {
    const sid = String(sessionId || "").trim();
    if (!sid) return;
    const prev = sessions.get(sid) || {};
    const code = normalizeSessionCode(
        data.sessionCode || data.sessionCodeRaw || prev.sessionCode || "",
    );
    sessions.set(sid, {sessionCode: code || prev.sessionCode});
  };

  await forEachQueryPage(
      db,
      db.collection(SESSIONS_COL).where("listId", "==", listId),
      async (docs) => {
        for (const doc of docs) addSession(doc.id, doc.data() || {});
      },
  );

  const addFromRow = (data) => {
    const sid = String(data.sessionId || "").trim();
    if (!sid) return;
    addSession(sid, data);
  };

  await forEachQueryPage(
      db,
      db.collection(RECORDS_COL).where("listId", "==", listId),
      async (docs) => {
        for (const doc of docs) addFromRow(doc.data() || {});
      },
  );
  await forEachQueryPage(
      db,
      db.collection(ATTEMPTS_COL).where("listId", "==", listId),
      async (docs) => {
        for (const doc of docs) addFromRow(doc.data() || {});
      },
  );

  await forEachQueryPage(
      db,
      db.collection(DEVICE_LOCKS_COL).where("listId", "==", listId),
      async (docs) => {
        for (const doc of docs) addFromRow(doc.data() || {});
      },
  );

  return sessions;
}

/**
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} sessionId
 * @returns {Promise<{studentIds: string[], recordIds: string[]}>}
 */
async function collectSessionRtdTargets(db, sessionId) {
  const sid = String(sessionId || "").trim();
  /** @type {Set<string>} */
  const studentIds = new Set();
  /** @type {Set<string>} */
  const recordIds = new Set();

  const collectFromDocs = (docs) => {
    for (const doc of docs) {
      recordIds.add(doc.id);
      const stu = String(doc.data()?.studentId || "").trim();
      if (stu) studentIds.add(stu);
    }
  };

  await forEachQueryPage(
      db,
      db.collection(RECORDS_COL).where("sessionId", "==", sid),
      async (docs) => collectFromDocs(docs),
  );
  await forEachQueryPage(
      db,
      db.collection(ATTEMPTS_COL).where("sessionId", "==", sid),
      async (docs) => collectFromDocs(docs),
  );

  return {
    studentIds: [...studentIds],
    recordIds: [...recordIds],
  };
}

/**
 * Removes Realtime Database mirrors for one session removed with its list.
 * @param {string} sessionId
 * @param {string} listId
 * @param {{sessionCode?: string}} meta
 * @param {string[]} studentIds
 * @param {string[]} recordIds
 */
async function purgeSessionRtdForListDelete(
    sessionId,
    listId,
    meta,
    studentIds,
    recordIds,
) {
  const sid = String(sessionId || "").trim();
  if (!sid) return;
  const lid = String(listId || "").trim();
  const code = normalizeSessionCode(meta?.sessionCode || "");

  /** @type {Record<string, unknown>} */
  const updates = {
    [`${RTD_ATTENDANCE_SESSIONS}/by_id/${sid}`]: null,
    [`${RTD_ATTENDANCE_RECORDS}/by_session/${sid}`]: null,
    [`${RTD_ATTENDANCE_ROLL_STATS}/by_session/${sid}`]: null,
    [`${RTD_CHECK_IN_CONFIRMATIONS}/by_session/${sid}`]: null,
  };
  if (code) {
    updates[`${RTD_ATTENDANCE_SESSIONS}/by_code/${code}/${sid}`] = null;
  }
  if (lid) {
    updates[`${RTD_ATTENDANCE_SESSIONS}/by_list/${lid}/${sid}`] = null;
    updates[`${RTD_ATTENDANCE_ROLL_STATS}/by_list/${lid}/${sid}`] = null;
  }
  for (const studentId of studentIds) {
    const stu = String(studentId || "").trim();
    if (!stu) continue;
    updates[`${RTD_ATTENDANCE_RECORDS}/by_student/${stu}/${sid}`] = null;
    updates[`${RTD_CHECK_IN_CONFIRMATIONS}/by_student/${stu}/${sid}`] = null;
  }
  for (const recordId of recordIds) {
    const rid = String(recordId || "").trim();
    if (!rid) continue;
    updates[`${RTD_CHECK_IN_CONFIRMATIONS}/by_record/${rid}`] = null;
  }
  await applyRtdUpdates(updates);
}

/**
 * Server-side cascade when an attendance list document is removed.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} listId
 */
async function cascadeDeleteAttendanceList(db, listId) {
  const trimmed = String(listId || "").trim();
  if (!trimmed) return;

  const sessions = await collectSessionsForListDelete(db, trimmed);

  for (const [sessionId, meta] of sessions) {
    const {studentIds, recordIds} = await collectSessionRtdTargets(db, sessionId);
    await purgeSessionRtdForListDelete(
        sessionId,
        trimmed,
        meta,
        studentIds,
        recordIds,
    );
    await deleteQueryInBatches(
        db,
        db.collection(DEVICE_LOCKS_COL).where("sessionId", "==", sessionId),
    );
    await deleteQueryInBatches(
        db,
        db.collection(RECORDS_COL).where("sessionId", "==", sessionId),
    );
    await deleteQueryInBatches(
        db,
        db.collection(ATTEMPTS_COL).where("sessionId", "==", sessionId),
    );
    await deleteQueryInBatches(
        db,
        db.collection("notices").where("sessionId", "==", sessionId),
    );
  }

  await applyRtdUpdates({
    [`${RTD_ATTENDANCE_SESSIONS}/by_list/${trimmed}`]: null,
    [`${RTD_ATTENDANCE_ROLL_STATS}/by_list/${trimmed}`]: null,
  });

  await deleteQueryInBatches(
      db,
      db.collection(ATTEMPTS_COL).where("listId", "==", trimmed),
  );
  await deleteQueryInBatches(
      db,
      db.collection(RECORDS_COL).where("listId", "==", trimmed),
  );
  await deleteQueryInBatches(
      db,
      db.collection(SESSIONS_COL).where("listId", "==", trimmed),
  );
  await deleteQueryInBatches(
      db,
      db.collection("sign_ins").where("listId", "==", trimmed),
  );
  await deleteQueryInBatches(
      db,
      db.collection("notices").where("targetListId", "==", trimmed),
  );
  await deleteQueryInBatches(
      db,
      db.collection(DEVICE_LOCKS_COL).where("listId", "==", trimmed),
  );
  logInfo("cascade_delete_attendance_list_done", {
    listId: trimmed,
    sessionCount: sessions.size,
  });
}

exports.onAttendanceListDeleted = onDocumentDeleted(
  {
    document: "attendance_lists/{listId}",
    database: "upanel",
    region: FUNCTION_REGION,
  },
  async (event) => {
    const listId = String(event.params.listId || "").trim();
    if (!listId) return null;
    try {
      await cascadeDeleteAttendanceList(upanelDb(), listId);
    } catch (e) {
      logError("onAttendanceListDeleted_failed", e, {listId});
    }
    return null;
  },
);

/** Backfill prior-session absents when an official **present** row lands. */
exports.onAttendanceRecordWrittenBackfillAbsents = onDocumentWritten(
  {
    document: `${RECORDS_COL}/{recordId}`,
    database: "upanel",
    region: FUNCTION_REGION,
  },
  async (event) => {
    const afterSnap = event.data?.after;
    if (!afterSnap?.exists) return null;
    const after = afterSnap.data() || {};
    const studentId = String(after.studentId || "").trim();
    const sessionId = String(after.sessionId || "").trim();
    if (!studentId || !sessionId) return null;

    const db = upanelDb();
    let listId = String(after.listId || "").trim();
    if (!listId) {
      const sessSnap = await db.collection(SESSIONS_COL).doc(sessionId).get();
      if (sessSnap.exists) {
        listId = String(sessSnap.data()?.listId || "").trim();
      }
    }

    try {
      await publishAttendanceRecordToRtd(db, {
        sessionId,
        studentId,
        present: after.present === true,
        verified: after.verified === true,
        course: after.course,
        timestampMs: firestoreTimestampToMillis(after.timestamp) ?? Date.now(),
        latitude: Number(after.latitude) || 0,
        longitude: Number(after.longitude) || 0,
        deviceId: after.deviceId,
        recordId: afterSnap.id,
        listId,
      });
      if (listId) {
        await publishSessionRollStatsToRtd(db, sessionId, listId);
      }
    } catch (e) {
      logError("onAttendanceRecordWritten_rtd_mirror", e, {
        sessionId,
        studentId,
      });
    }

    if (after.present !== true) return null;
    if (!listId) return null;

    try {
      await upgradeMetadataMatchedAbsentRecordsForStudentOnList(
          db,
          listId,
          studentId,
      );
      const signSnap = await db.collection("sign_ins")
          .where("listId", "==", listId)
          .where("studentId", "==", studentId)
          .limit(1)
          .get();
      const course = signSnap.docs.length > 0 ?
        String(signSnap.docs[0].data()?.course || "").trim() :
        String(after.course || "").trim();
      const signedInAt = signSnap.docs.length > 0 ?
        signSnap.docs[0].data()?.signedInAt :
        undefined;
      await backfillAbsentRecordsForStudentOnList(
          db,
          listId,
          studentId,
          course,
          signedInAt,
      );
    } catch (e) {
      logError("onAttendanceRecordWrittenBackfill_failed", e, {
        sessionId,
        studentId,
        listId,
      });
    }
    return null;
  },
);

exports.onSignInWrittenBackfillAbsents = onDocumentWritten(
  {
    document: "sign_ins/{signInId}",
    database: "upanel",
    region: FUNCTION_REGION,
  },
  async (event) => {
    const afterSnap = event.data?.after;
    if (!afterSnap?.exists) return null;
    const after = afterSnap.data() || {};
    const before = event.data?.before?.exists ?
      (event.data.before.data() || {}) :
      null;
    const isCreate = !event.data?.before?.exists;
    const backfillBump =
      after.backfillRequestedAt &&
      (!before || after.backfillRequestedAt !== before.backfillRequestedAt);
    if (!isCreate && !backfillBump) return null;

    const listId = String(after.listId || "").trim();
    const studentId = String(after.studentId || "").trim();
    const course = String(after.course || "").trim();
    if (!listId || !studentId) return null;
    try {
      await backfillAbsentRecordsForStudentOnList(
          upanelDb(),
          listId,
          studentId,
          course,
          after.signedInAt,
      );
    } catch (e) {
      console.error("onSignInWrittenBackfillAbsents failed", afterSnap.id, e);
    }
    return null;
  },
);

exports.onCheckInAttemptWritten = onDocumentWritten(
  {
    document: `${ATTEMPTS_COL}/{docId}`,
    database: "upanel",
    region: FUNCTION_REGION,
  },
  async (event) => {
    const after = event.data?.after;
    if (!after?.exists) return null;
    const data = after.data() || {};
    const db = upanelDb();
    if (data.status === "pending") {
      try {
        await reconcileCheckInAttempt(db, after);
      } catch (e) {
        console.error("reconcileCheckInAttempt failed", after.id, e);
      }
    }
    const studentId = String(data.studentId || "").trim();
    if (!studentId) return null;
    let listId = String(data.listId || "").trim();
    if (!listId) {
      const sessionId = String(data.sessionId || "").trim();
      if (sessionId) {
        listId = await resolveListIdForSessionId(db, sessionId);
      }
    }
    if (!listId) return null;
    try {
      await upgradeMetadataMatchedAbsentRecordsForStudentOnList(
          db,
          listId,
          studentId,
      );
    } catch (e) {
      console.error("upgradeMetadataMatchedAbsent failed", after.id, e);
    }
    return null;
  },
);

/** When a lecturer session syncs, match pending code+location claims waiting online. */
exports.onAttendanceSessionWritten = onDocumentWritten(
  {
    document: `${SESSIONS_COL}/{sessionId}`,
    database: "upanel",
    region: FUNCTION_REGION,
  },
  async (event) => {
    const after = event.data?.after;
    const sessionId = event.params.sessionId;
    if (!after?.exists) {
      const before = event.data?.before?.exists ?
        (event.data.before.data() || {}) :
        {};
      await publishSessionToRtd(sessionId, before, {remove: true});
      return null;
    }
    const session = after.data() || {};
    const before = event.data?.before?.exists ?
      (event.data.before.data() || {}) :
      null;
    const db = upanelDb();
    try {
      const geofenceNowReady =
        session.remoteLearning === true ||
        isSessionGeofenceConfigured(session);
      const geofenceWasReady = before &&
        (before.remoteLearning === true || isSessionGeofenceConfigured(before));
      if (geofenceNowReady && !geofenceWasReady) {
        try {
          await after.ref.update({awaitingStudentMetadata: false});
        } catch (_) {}
      }
      await reconcilePendingAttemptsForSession(db, sessionId, session);
      const code = normalizeSessionCode(session.sessionCode);
      if (!code) return null;
      await forEachQueryPage(
          db,
          db.collection(ATTEMPTS_COL)
              .where("awaitingSession", "==", true)
              .where("sessionCodeRaw", "==", code)
              .where("status", "==", "pending"),
          async (docs) => {
            for (const doc of docs) {
              try {
                await reconcileCheckInAttempt(db, doc);
              } catch (e) {
                logError("reconcile_awaiting_claim", e, {
                  attemptId: doc.id,
                  sessionId,
                });
              }
            }
          },
      );
    } catch (e) {
      logError("onAttendanceSessionWritten_failed", e, {sessionId});
    }
    try {
      await publishSessionToRtd(sessionId, session);
    } catch (e) {
      logError("publish_session_rtd_hook", e, {sessionId});
    }
    return null;
  },
);

/** Reconcile pending check-ins when a running session appears on RTD. */
exports.onRunningSessionRtdWritten = onValueWritten(
  {
    ref: `${RTD_ATTENDANCE_SESSIONS}/by_id/{sessionId}`,
    instance: "u-panel-2026-default-rtdb",
    region: "europe-west1",
  },
  async (event) => {
    const after = event.data.after.val();
    if (!after || typeof after !== "object") return null;
    if (String(after.status || "").trim().toLowerCase() !== "active") return null;
    const sessionId = event.params.sessionId;
    const db = upanelDb();
    try {
      await reconcilePendingAttemptsForSession(db, sessionId, after);
      const code = normalizeSessionCode(after.sessionCode);
      if (!code) return null;
      await forEachQueryPage(
          db,
          db.collection(ATTEMPTS_COL)
              .where("awaitingSession", "==", true)
              .where("sessionCodeRaw", "==", code)
              .where("status", "==", "pending"),
          async (docs) => {
            for (const doc of docs) {
              try {
                await reconcileCheckInAttempt(db, doc);
              } catch (e) {
                logError("rtd_reconcile_awaiting_claim", e, {
                  attemptId: doc.id,
                  sessionId,
                });
              }
            }
          },
      );
    } catch (e) {
      logError("onRunningSessionRtdWritten_failed", e, {sessionId});
    }
    return null;
  },
);

/**
 * Reconcile every pending check_in_attempt (backup to realtime triggers).
 * @param {FirebaseFirestore.Firestore} db
 */
async function reconcileAllPendingCheckInAttempts(db) {
  let processed = 0;
  await forEachQueryPage(
      db,
      db.collection(ATTEMPTS_COL).where("status", "==", "pending"),
      async (docs) => {
        for (const doc of docs) {
          try {
            await reconcileCheckInAttempt(db, doc);
            processed++;
            const d = doc.data() || {};
            const studentId = String(d.studentId || "").trim();
            let listId = String(d.listId || "").trim();
            if (!listId) {
              const sessionId = String(d.sessionId || "").trim();
              if (sessionId) {
                listId = await resolveListIdForSessionId(db, sessionId);
              }
            }
            if (listId && studentId) {
              await upgradeMetadataMatchedAbsentRecordsForStudentOnList(
                  db,
                  listId,
                  studentId,
              );
            }
          } catch (e) {
            logError("scheduled_reconcile_failed", e, {
              attemptId: doc.id,
            });
          }
        }
      },
  );
  logInfo("reconcilePendingCheckInAttempts_done", {processed});
}

/**
 * @param {string} uid
 * @returns {Promise<{isAdmin: boolean, isLecturer: boolean}>}
 */
async function resolveStaffAccessFlags(uid) {
  const id = String(uid || "").trim();
  if (!id) return {isAdmin: false, isLecturer: false};
  const db = upanelDb();
  let isAdmin = false;
  let isLecturer = false;
  try {
    const adminSnap = await db.collection("admins").doc(id).get();
    if (adminSnap.exists) {
      const data = adminSnap.data() || {};
      isAdmin = isTruthyFlag(data.isAdmin) || isTruthyFlag(data.isadmin);
    }
    if (!isAdmin) {
      const legacySnap = await db.collection("admin").doc(id).get();
      if (legacySnap.exists) {
        const data = legacySnap.data() || {};
        isAdmin = isTruthyFlag(data.isAdmin) || isTruthyFlag(data.isadmin);
      }
    }
    const lectSnap = await db.collection("lecturers").doc(id).get();
    if (lectSnap.exists) {
      const data = lectSnap.data() || {};
      isLecturer = isTruthyFlag(data.isLecturer) || isTruthyFlag(data.islecturer);
    }
  } catch (e) {
    logError("resolve_staff_access_flags", e, {uid: id});
  }
  return {isAdmin, isLecturer};
}

/** Mirror admins/{uid} to RTD staff_access for security rules. */
exports.onAdminWrittenMirrorStaffAccess = onDocumentWritten(
  {
    document: "admins/{uid}",
    database: "upanel",
    region: FUNCTION_REGION,
  },
  async (event) => {
    const uid = String(event.params.uid || "").trim();
    if (!uid) return null;
    const flags = await resolveStaffAccessFlags(uid);
    if (flags.isAdmin || flags.isLecturer) {
      await publishStaffAccessToRtd(uid, flags);
    } else {
      await removeStaffAccessFromRtd(uid);
    }
    return null;
  },
);

/** Mirror lecturers/{uid} to RTD staff_access for security rules. */
exports.onLecturerWrittenMirrorStaffAccess = onDocumentWritten(
  {
    document: "lecturers/{uid}",
    database: "upanel",
    region: FUNCTION_REGION,
  },
  async (event) => {
    const uid = String(event.params.uid || "").trim();
    if (!uid) return null;
    const flags = await resolveStaffAccessFlags(uid);
    if (flags.isAdmin || flags.isLecturer) {
      await publishStaffAccessToRtd(uid, flags);
    } else {
      await removeStaffAccessFromRtd(uid);
    }
    return null;
  },
);
