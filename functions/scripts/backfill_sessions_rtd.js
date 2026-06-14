/**
 * One-off backfill: mirror all Firestore `attendance_sessions` (database `upanel`)
 * into Realtime Database under `attendance_sessions/`.
 *
 * Credentials (pick one):
 *   - Save a Firebase service account JSON as `functions/service-account.json`
 *   - Set GOOGLE_APPLICATION_CREDENTIALS to the key file path
 *   - Pass --credentials=C:\path\to\key.json
 *   - Or install Google Cloud SDK: gcloud auth application-default login
 *
 * Easiest on Windows (no gcloud):
 *   1. Firebase Console → Project settings → Service accounts → Generate new private key
 *   2. Save as functions/service-account.json
 *   3. From repo root: .\scripts\run-backfill-sessions-rtd.ps1
 *
 * Usage (from `functions/`):
 *   npm run backfill-sessions-rtd
 *   npm run backfill-sessions-rtd -- --dry-run
 *   npm run backfill-sessions-rtd -- --limit=50
 *   npm run backfill-sessions-rtd -- --credentials=..\secrets\key.json
 */
const fs = require("fs");
const path = require("path");
const admin = require("firebase-admin");
const {FieldPath, getFirestore} = require("firebase-admin/firestore");

const SESSIONS_COL = "attendance_sessions";
const RTD_ATTENDANCE_SESSIONS = "attendance_sessions";
const FIRESTORE_DATABASE_ID = "upanel";
const FIREBASE_PROJECT_ID = "u-panel-2026";
const RTD_DATABASE_URL =
  "https://u-panel-2026-default-rtdb.europe-west1.firebasedatabase.app";
const BATCH_KEY_LIMIT = 400;
const PAGE_SIZE = 300;
const FUNCTIONS_DIR = path.resolve(__dirname, "..");

/**
 * @returns {{dryRun: boolean, limit: number|null, credentials: string|null}}
 */
function parseArgs() {
  const dryRun = process.argv.includes("--dry-run");
  let limit = null;
  let credentials = null;
  for (const arg of process.argv.slice(2)) {
    if (arg.startsWith("--limit=")) {
      const n = Number(arg.slice("--limit=".length));
      if (Number.isFinite(n) && n > 0) limit = Math.floor(n);
    }
    if (arg.startsWith("--credentials=")) {
      credentials = arg.slice("--credentials=".length).trim();
    }
  }
  return {dryRun, limit, credentials};
}

/**
 * @param {string|null} cliPath
 * @returns {string|null}
 */
function resolveCredentialsPath(cliPath) {
  /** @type {string[]} */
  const candidates = [];
  if (cliPath) candidates.push(cliPath);
  if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    candidates.push(process.env.GOOGLE_APPLICATION_CREDENTIALS);
  }
  candidates.push(
      path.join(FUNCTIONS_DIR, "service-account.json"),
      path.join(FUNCTIONS_DIR, "u-panel-2026-firebase-adminsdk.json"),
      path.join(FUNCTIONS_DIR, "..", "secrets", "service-account.json"),
  );
  for (const candidate of candidates) {
    const resolved = path.resolve(candidate);
    if (fs.existsSync(resolved)) return resolved;
  }
  return null;
}

/**
 * @param {string|null} cliPath
 */
function initFirebaseAdmin(cliPath) {
  if (admin.apps.length) return;
  const keyPath = resolveCredentialsPath(cliPath);
  /** @type {import("firebase-admin").AppOptions} */
  const options = {
    projectId: FIREBASE_PROJECT_ID,
    databaseURL: RTD_DATABASE_URL,
  };
  if (keyPath) {
    options.credential = admin.credential.cert(require(keyPath));
    console.log(JSON.stringify({event: "backfill_credentials", source: keyPath}));
  }
  admin.initializeApp(options);
}

function printCredentialsHelp() {
  console.error("");
  console.error("Could not load Google credentials for firebase-admin.");
  console.error("");
  console.error("Firebase CLI login is not enough for this script. Use one of:");
  console.error("  1. Save a service account JSON as functions/service-account.json");
  console.error("  2. Set GOOGLE_APPLICATION_CREDENTIALS=C:\\path\\to\\key.json");
  console.error("  3. npm run backfill-sessions-rtd -- --credentials=C:\\path\\to\\key.json");
  console.error("  4. Install Google Cloud SDK: gcloud auth application-default login");
  console.error("");
  console.error("Download a key:");
  console.error("  https://console.firebase.google.com/project/u-panel-2026/settings/serviceaccounts/adminsdk");
  console.error("");
  console.error("Or from repo root:");
  console.error("  .\\scripts\\run-backfill-sessions-rtd.ps1");
  console.error("");
}

/**
 * @param {string} raw
 * @returns {string}
 */
function normalizeSessionCode(raw) {
  return String(raw || "").trim().replace(/\s+/g, "").toUpperCase();
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
 * @param {string} sessionId
 * @param {Record<string, unknown>} session
 * @returns {Record<string, unknown>}
 */
function sessionRtdUpdates(sessionId, session) {
  const sid = String(sessionId || "").trim();
  if (!sid) return {};
  const code = normalizeSessionCode(session.sessionCode);
  const listId = String(session.listId || "").trim();
  const status = String(session.status || "active").trim().toLowerCase();
  /** @type {Record<string, unknown>} */
  const updates = {};

  if (status === "closed") {
    const payload = buildSessionRtdPayload(sid, session);
    updates[`${RTD_ATTENDANCE_SESSIONS}/by_id/${sid}`] = payload;
    if (code) {
      updates[`${RTD_ATTENDANCE_SESSIONS}/by_code/${code}/${sid}`] = null;
    }
    if (listId) {
      updates[`${RTD_ATTENDANCE_SESSIONS}/by_list/${listId}/${sid}`] = payload;
    }
    return updates;
  }

  const payload = buildSessionRtdPayload(sid, session);
  updates[`${RTD_ATTENDANCE_SESSIONS}/by_id/${sid}`] = payload;
  if (code) {
    updates[`${RTD_ATTENDANCE_SESSIONS}/by_code/${code}/${sid}`] = payload;
  }
  if (listId) {
    updates[`${RTD_ATTENDANCE_SESSIONS}/by_list/${listId}/${sid}`] = payload;
  }
  return updates;
}

/**
 * @param {Record<string, unknown>} updates
 * @param {boolean} dryRun
 */
async function flushUpdates(updates, dryRun) {
  const keys = Object.keys(updates);
  if (keys.length === 0) return;
  if (dryRun) return;
  await admin.database().ref().update(updates);
}

async function main() {
  const {dryRun, limit, credentials} = parseArgs();
  initFirebaseAdmin(credentials);
  const db = getFirestore(admin.app(), FIRESTORE_DATABASE_ID);
  console.log(
      JSON.stringify({
        event: "backfill_sessions_rtd_start",
        database: FIRESTORE_DATABASE_ID,
        dryRun,
        limit,
      }),
  );

  let processed = 0;
  let activeIndexed = 0;
  let closedIndexed = 0;
  let batches = 0;
  /** @type {Record<string, unknown>} */
  let pending = {};

  const flushPending = async () => {
    const keyCount = Object.keys(pending).length;
    if (keyCount === 0) return;
    await flushUpdates(pending, dryRun);
    batches++;
    pending = {};
  };

  let lastDoc = null;
  while (true) {
    let query = db.collection(SESSIONS_COL).orderBy(FieldPath.documentId()).limit(PAGE_SIZE);
    if (lastDoc) query = query.startAfter(lastDoc);
    const snap = await query.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      if (limit != null && processed >= limit) break;
      const data = doc.data() || {};
      const status = String(data.status || "active").trim().toLowerCase();
      if (status === "closed") {
        closedIndexed++;
      } else {
        activeIndexed++;
      }

      const updates = sessionRtdUpdates(doc.id, data);
      for (const [k, v] of Object.entries(updates)) {
        pending[k] = v;
        if (Object.keys(pending).length >= BATCH_KEY_LIMIT) {
          await flushPending();
        }
      }
      processed++;
    }

    if (limit != null && processed >= limit) break;
    lastDoc = snap.docs[snap.docs.length - 1];
    if (snap.size < PAGE_SIZE) break;
  }

  await flushPending();

  console.log(
      JSON.stringify({
        event: "backfill_sessions_rtd_done",
        processed,
        activeIndexed,
        closedIndexed,
        batches,
        dryRun,
      }),
  );

  if (dryRun) {
    console.log("Dry run only — no RTD writes were made.");
  } else {
    console.log(`Mirrored ${processed} session(s) to RTD in ${batches} batch(es).`);
  }
}

main().catch((err) => {
  const message = String(err && err.message ? err.message : err);
  if (message.includes("Could not load the default credentials")) {
    printCredentialsHelp();
    process.exit(1);
  }
  console.error("backfill_sessions_rtd_failed", err);
  process.exit(1);
});
