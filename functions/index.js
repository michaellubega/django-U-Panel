/**
 * U-Panel Cloud Functions (Firestore database `upanel`).
 *
 * - FCM on new notices (all_notices, list_<id>, stu_<studentId>)
 * - Session notice TTL cleanup
 * - Attendance session lifecycle: finalize roll + missed notices (active/scheduled
 *   past endTime, plus client-closed sessions not yet finalized)
 * - After roll finalize: missed check-in notices + push to each absent student
 *
 * Deploy: `npm install` in `functions/`, then `firebase deploy --only functions`.
 * Composite indexes: see repo `firestore.indexes.json`.
 */
const {
  onDocumentCreated,
} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const {
  getFirestore,
  FieldValue,
  Timestamp,
} = require("firebase-admin/firestore");

if (!admin.apps.length) {
  admin.initializeApp();
}

/** @returns {FirebaseFirestore.Firestore} */
function upanelDb() {
  return getFirestore(admin.app(), "upanel");
}

/** @param {string} raw */
function sanitizeFcmTopicSegment(raw) {
  return raw.replace(/[^a-zA-Z0-9-_.~%]/g, "_");
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
async function finalizeRollForSessionInDb(db, sessionId, listId) {
  const sessionsCol = "attendance_sessions";
  const sessionRef = db.collection(sessionsCol).doc(sessionId);
  const sessSnap = await sessionRef.get();
  if (!sessSnap.exists) return;
  const sessData = sessSnap.data() || {};
  if (sessData.finalized === true) return;

  const recordsCol = "attendance_records";
  const signInsCol = "sign_ins";
  const emDash = "\u2014";

  const signSnap = await db
      .collection(signInsCol)
      .where("listId", "==", listId)
      .get();
  /** @type {Map<string, string>} */
  const courseByStudent = new Map();
  /** @type {Map<string, FirebaseFirestore.Timestamp>} earliest sign-in per student */
  const earliestSignedInByStudent = new Map();
  for (const doc of signSnap.docs) {
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

  const sessionEndTs = sessData.endTime;

  const recSnap = await db
      .collection(recordsCol)
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
    const ref = db.collection(recordsCol).doc(`${sessionId}_${studentId}`);
    batch.set(ref, {
      sessionId,
      studentId,
      course,
      timestamp: ts,
      latitude: 0,
      longitude: 0,
      selfieStoragePath: null,
      verified: false,
      present: false,
      serverReceivedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    n++;
    if (n >= 400) {
      await batch.commit();
      batch = db.batch();
      n = 0;
    }
  }
  if (n > 0) {
    await batch.commit();
  }

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
    const ex = await ref.get();
    if (ex.exists) continue;
    try {
      await ref.create({
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
    } catch (err) {
      const code = err && err.code;
      if (code === 6 || code === "ALREADY_EXISTS") continue;
      console.error("missed notice create failed", noticeId, err);
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
    await finalizeRollForSessionInDb(db, doc.id, listId);
    await doc.ref.update({
      status: "closed",
      finalized: true,
      finalizedAt: FieldValue.serverTimestamp(),
    });
  } catch (e) {
    console.error("closeEndedSessionsAndFinalize failed", doc.id, e);
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
    const snap = await db.collection(sessionsCol)
        .where("status", "==", st)
        .where("endTime", "<=", now)
        .limit(50)
        .get();
    for (const doc of snap.docs) {
      await finalizeOneSessionDoc(db, doc);
    }
  }

  /** @type {Set<string>} */
  const closedSeen = new Set();
  try {
    const closedExplicit = await db.collection(sessionsCol)
        .where("status", "==", "closed")
        .where("finalized", "==", false)
        .limit(50)
        .get();
    for (const doc of closedExplicit.docs) {
      closedSeen.add(doc.id);
      await finalizeOneSessionDoc(db, doc);
    }
  } catch (e) {
    console.error("closed finalized==false query (add composite index?)", e);
  }

  const closedLegacy = await db.collection(sessionsCol)
      .where("status", "==", "closed")
      .limit(60)
      .get();
  for (const doc of closedLegacy.docs) {
    if (closedSeen.has(doc.id)) continue;
    const data = doc.data() || {};
    if (data.finalized === true) continue;
    await finalizeOneSessionDoc(db, doc);
  }
}

exports.onNoticeCreatedSendPush = onDocumentCreated(
  {
    document: "notices/{noticeId}",
    database: "upanel",
    region: "us-central1",
  },
  async (event) => {
    const snap = event.data;
    if (!snap) {
      return null;
    }
    const data = snap.data() || {};
    const sendPush = data.sendPush !== false;
    if (!sendPush) {
      console.log("Push skipped (sendPush=false)", {
        noticeId: String(event.params.noticeId || ""),
      });
      return null;
    }
    const {title, body} = userFacingPushCopy(data);

    const audience = (data.audience || "allAppUsers")
      .toString()
      .trim()
      .toLowerCase();
    let topic;
    if (audience === "student" || audience === "targetstudent") {
      const rawStu = (data.targetStudentId || "").toString().trim();
      if (!rawStu) {
        console.warn("student notice missing targetStudentId; skip FCM");
        return null;
      }
      topic = "stu_" + sanitizeFcmTopicSegment(rawStu);
    } else if (audience === "classlist" || audience === "class_list") {
      const rawId = (data.targetListId || "").toString().trim();
      if (!rawId) {
        console.warn("classList notice missing targetListId; skip FCM");
        return null;
      }
      topic = "list_" + sanitizeFcmTopicSegment(rawId);
    } else {
      topic = "all_notices";
    }

    /** @type {import('firebase-admin').messaging.Message} */
    const message = {
      topic,
      notification: {title, body},
      data: {
        noticeId: String(event.params.noticeId || ""),
        kind: (data.kind || "").toString(),
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

    try {
      const id = await admin.messaging().send(message);
      console.log("Push sent", {
        id,
        topic,
        noticeId: String(event.params.noticeId || ""),
      });
    } catch (e) {
      console.error("FCM send failed", e);
    }
    return null;
  },
);

exports.deleteExpiredSessionNotices = onSchedule(
  {
    schedule: "every 15 minutes",
    region: "us-central1",
    timeZone: "UTC",
  },
  async () => {
    const now = Timestamp.now();
    const cutoff = Timestamp.fromMillis(
        Date.now() - 3 * 60 * 60 * 1000,
    );
    const db = upanelDb();
    const byExpirySnap = await db.collection("notices")
        .where("expiresAt", "<=", now)
        .limit(400)
        .get();
    const byCreatedAtSnap = await db.collection("notices")
        .where("kind", "==", "sessionCode")
        .where("createdAt", "<=", cutoff)
        .limit(400)
        .get();
    if (byExpirySnap.empty && byCreatedAtSnap.empty) {
      return null;
    }

    const refs = new Map();
    for (const doc of byExpirySnap.docs) {
      refs.set(doc.ref.path, doc.ref);
    }
    for (const doc of byCreatedAtSnap.docs) {
      refs.set(doc.ref.path, doc.ref);
    }

    const batch = db.batch();
    for (const ref of refs.values()) {
      batch.delete(ref);
    }
    await batch.commit();
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
    region: "us-central1",
    timeZone: "UTC",
  },
  async () => {
    const db = upanelDb();
    const now = Timestamp.now();
    const sessionsCol = "attendance_sessions";
    await closeEndedSessionsAndFinalize(db, sessionsCol, now);
    return null;
  },
);
