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
 *   session verified but wrong time/GPS → rejected + marked absent immediately
 * - Retroactive absent backfill when a student joins a list (sign_ins trigger)
 * - Cascade delete sessions, records (by sessionId and listId), attempts,
 *   sign-ins, notices (by listId, sessionId, and targetListId) when a list
 *   is removed
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
const admin = require("firebase-admin");
const crypto = require("crypto");
const {
  getFirestore,
  FieldValue,
  Timestamp,
} = require("firebase-admin/firestore");

if (!admin.apps.length) {
  admin.initializeApp();
}

const FUNCTION_REGION =
  process.env.FUNCTION_REGION || process.env.GCLOUD_REGION || "us-central1";
const ATTEMPTS_COL = "check_in_attempts";
const RECORDS_COL = "attendance_records";
const SESSIONS_COL = "attendance_sessions";
const DEVICE_LOCKS_COL = "device_session_locks";
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
  if (endMs > 0 && Date.now() - endMs < GRACE_MS) {
    logInfo("finalize_roll_deferred_grace", {sessionId, listId});
    return;
  }

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
      checkInAttemptQualifiesForPresentCorrection(ad, sessData, listId)
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
  for (const {studentId, course} of writes) {
    if (metadataMatchedSnaps.has(studentId)) continue;

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
        checkInAttemptQualifiesForPresentCorrection(ad, sessData, listId)
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
    absentCount: writes.length,
  });

  if (writes.length > 0) {
    await createMissedCheckInNoticesForStudents(
        db,
        sessionId,
        listId,
        writes,
        sessionEndTs,
        courseByStudent,
        earliestSignedInByStudent,
    );
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
    const graceExpired = endMs <= 0 || Date.now() - endMs >= GRACE_MS;
    if (!graceExpired) {
      if (data.status !== "closed") {
        await doc.ref.update({status: "closed"});
      }
      logInfo("session_closed_pending_grace", {sessionId: doc.id, listId});
      return;
    }
    await finalizeRollForSessionInDb(db, doc.id, listId);
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
    return runWithLease(db, "sessionLifecycleScheduler", 15 * 60 * 1000,
        async () => {
          await closeEndedSessionsAndFinalize(db, SESSIONS_COL, now);
          logInfo("sessionLifecycleScheduler_done", {});
          return null;
        });
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
 * Defer absent writes only while check-in evidence is still incomplete.
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
    if (String(d.status || "").trim().toLowerCase() !== "pending") return false;
    if (!studentAttemptMissingMetadataForPending(d)) return false;
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
  const start = session.startTime;
  const end = session.endTime;
  if (!start || !end || typeof start.toMillis !== "function") return false;
  if (typeof end.toMillis !== "function") return false;
  if (typeof capturedAt.toMillis !== "function") return false;
  const t = capturedAt.toMillis();
  if (t < start.toMillis()) return false;
  if (t <= end.toMillis()) return true;
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
  const radius = Number(session.radiusMeters);
  if (!Number.isFinite(radius) || radius <= 0) return false;
  const centerLat = Number(session.latitude);
  const centerLng = Number(session.longitude);
  return isValidCheckInCoordinates(centerLat, centerLng);
}

/**
 * @param {Record<string, unknown>} session
 * @param {number} lat
 * @param {number} lng
 */
function isPositionWithinSession(session, lat, lng) {
  if (session.remoteLearning === true) return true;
  if (!isSessionGeofenceConfigured(session)) return false;
  if (!isValidCheckInCoordinates(lat, lng)) return false;
  const centerLat = Number(session.latitude);
  const centerLng = Number(session.longitude);
  const radius = Number(session.radiusMeters);
  return distanceMeters(centerLat, centerLng, lat, lng) <= radius;
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

  const lat = Number(attemptData.latitude);
  const lng = Number(attemptData.longitude);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return false;
  if (!isTimestampWithinSessionBounds(session, attemptData.capturedAt)) {
    return false;
  }
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
      return checkInAttemptQualifiesForPresentCorrection(d, session, listId) ?
        snap :
        null;
    }
    if (
      st === "pending" &&
      checkInAttemptQualifiesForPresentCorrection(d, session, listId)
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
    deviceId,
    studentId,
    attemptId: attemptSnap.id,
    capturedAt,
  });
  if (!claim.allowed) {
    const st = String(data.status || "").trim().toLowerCase();
    if (st === "pending") {
      await attemptSnap.ref.update({
        status: "rejected",
        rejectionReason: claim.reason ||
          "Device already used for another student this session.",
        sessionId,
        processedAt: FieldValue.serverTimestamp(),
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
      if (checkInAttemptQualifiesForPresentCorrection(d, session, listId)) {
        const sid = String(d.studentId || "").trim();
        if (sid) matched.set(sid, doc);
      }
      return;
    }
    if (studentAttemptMissingMetadataForPending(d)) return;
    if (!checkInAttemptQualifiesForPresentCorrection(d, session, listId)) return;
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
 * Resolve session by doc id or by sessionCode / sessionCodeRaw on the attempt.
 * @param {FirebaseFirestore.Firestore} db
 * @param {Record<string, unknown>} data
 * @returns {Promise<{sessionId: string, session: Record<string, unknown>}|null>}
 */
async function resolveSessionForAttempt(db, data) {
  const capturedAt = data.capturedAt;
  const sessionIdRaw = String(data.sessionId || "").trim();
  if (sessionIdRaw) {
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

  /** @type {Map<string, FirebaseFirestore.QueryDocumentSnapshot>} */
  const docsById = new Map();

  try {
    const activeSnap = await db.collection(SESSIONS_COL)
        .where("sessionCode", "==", code)
        .where("status", "==", "active")
        .limit(8)
        .get();
    for (const doc of activeSnap.docs) {
      docsById.set(doc.id, doc);
    }
  } catch (e) {
    logWarn("resolveSessionForAttempt_active_query_failed", {code, error: String(e)});
  }

  if (docsById.size < 16) {
    const snap = await db.collection(SESSIONS_COL)
        .where("sessionCode", "==", code)
        .limit(16)
        .get();
    for (const doc of snap.docs) {
      if (!docsById.has(doc.id)) docsById.set(doc.id, doc);
    }
  }

  if (docsById.size === 0) return null;

  /** @type {{sessionId: string, session: Record<string, unknown>}|null} */
  let bounded = null;
  /** @type {{sessionId: string, session: Record<string, unknown>}|null} */
  let bestActive = null;

  for (const doc of docsById.values()) {
    const session = doc.data() || {};
    const entry = {sessionId: doc.id, session};

    if (isSessionOpenForCheckIn(session)) {
      if (!bestActive) {
        bestActive = entry;
      } else {
        const startA = session.startTime;
        const startB = bestActive.session.startTime;
        if (
          startA && startB &&
          typeof startA.toMillis === "function" &&
          typeof startB.toMillis === "function" &&
          startA.toMillis() > startB.toMillis()
        ) {
          bestActive = entry;
        }
      }
    }

    if (
      capturedAt &&
      typeof capturedAt.toMillis === "function" &&
      isTimestampWithinSessionBounds(session, capturedAt)
    ) {
      if (!bounded) {
        bounded = entry;
      } else {
        const startA = session.startTime;
        const startB = bounded.session.startTime;
        if (
          startA && startB &&
          typeof startA.toMillis === "function" &&
          typeof startB.toMillis === "function" &&
          startA.toMillis() > startB.toMillis()
        ) {
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
    checkInAttemptMatchesSessionMetadata(
        attemptData,
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
      tx.set(lockRef, {
        sessionId: sid,
        deviceId: did,
        studentId: stu,
        attemptId: att,
        capturedAt: capturedAt || null,
        lockedAt: FieldValue.serverTimestamp(),
      });
      return true;
    }

    const lock = lockSnap.data() || {};
    const winner = String(lock.studentId || "").trim();
    if (winner === stu) return true;

    const winnerMs = capturedAtToMillis(lock.capturedAt);
    if (attemptMs > 0 && (winnerMs === 0 || attemptMs < winnerMs)) {
      supersededStudentId = winner;
      tx.set(lockRef, {
        sessionId: sid,
        deviceId: did,
        studentId: stu,
        attemptId: att,
        capturedAt: capturedAt || null,
        lockedAt: FieldValue.serverTimestamp(),
        supersededStudentId: winner,
      });
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
    const hintSnap = await db.collection(SESSIONS_COL).doc(hintedSessionId).get();
    if (!hintSnap.exists) {
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
    await reject("Session does not match list.", sessionId, false, session);
    return;
  }

  const withinTime = isTimestampWithinSessionBounds(session, capturedAt);
  const withinRadius =
    Number.isFinite(latitude) &&
    Number.isFinite(longitude) &&
    isPositionWithinSession(session, latitude, longitude);

  if (!withinTime || !withinRadius) {
    const reason = !withinTime ?
      "Captured outside session time window." :
      "Outside class location radius at capture time.";
    await reject(reason, sessionId, true, session);
    return;
  }

  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
    await reject("Invalid GPS coordinates.", sessionId, true, session);
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
    return;
  }

  const claim = await claimDeviceForSessionPresent(db, {
    sessionId,
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
    if (checkInAttemptQualifiesForPresentCorrection(ad, session, listId)) {
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
      const graceExpired = nowMs - endMs > GRACE_MS;
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
          checkInAttemptQualifiesForPresentCorrection(ad, s, listId)
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
 * Server-side cascade when an attendance list document is removed.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} listId
 */
async function cascadeDeleteAttendanceList(db, listId) {
  const trimmed = String(listId || "").trim();
  if (!trimmed) return;

  /** @type {string[]} */
  const sessionIds = [];
  await forEachQueryPage(
      db,
      db.collection(SESSIONS_COL).where("listId", "==", trimmed),
      async (docs) => {
        for (const doc of docs) sessionIds.push(doc.id);
      },
  );

  for (const sessionId of sessionIds) {
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
  logInfo("cascade_delete_attendance_list_done", {
    listId: trimmed,
    sessionCount: sessionIds.length,
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
        const sessSnap = await db.collection(SESSIONS_COL).doc(sessionId).get();
        if (sessSnap.exists) {
          listId = String(sessSnap.data()?.listId || "").trim();
        }
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
    if (!after?.exists) return null;
    const session = after.data() || {};
    const db = upanelDb();
    const sessionId = after.id;
    try {
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
    return null;
  },
);

/**
 * Periodically reconcile pending check-in attempts (e.g. session synced after
 * upload). Verified session + bad time/GPS → rejected immediately.
 */
exports.reconcilePendingCheckInAttempts = onSchedule(
  {
    schedule: "every 15 minutes",
    region: FUNCTION_REGION,
    timeZone: "UTC",
  },
  async () => {
    const db = upanelDb();
    return runWithLease(db, "reconcilePendingCheckInAttempts", 15 * 60 * 1000,
        async () => {
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
                        const sessSnap =
                          await db.collection(SESSIONS_COL).doc(sessionId).get();
                        if (sessSnap.exists) {
                          listId = String(sessSnap.data()?.listId || "").trim();
                        }
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
          return null;
        });
  },
);
