"""Check-in attempt processing (replaces Firebase Cloud Functions)."""

from __future__ import annotations

import math

from ..models import ApiDocument

CHECK_IN_COLLECTION = "attendance/check-in-attempts"
SESSIONS_COLLECTION = "attendance/sessions"
RECORDS_COLLECTION = "attendance/records"


def maybe_process_check_in(doc: ApiDocument) -> None:
    if doc.collection != CHECK_IN_COLLECTION:
        return
    data = dict(doc.data or {})
    status = (data.get("status") or "pending").strip().lower()
    if status not in ("", "pending"):
        return

    session_id = (data.get("sessionId") or "").strip()
    if not session_id or data.get("awaitingSession"):
        session_id = _link_session_by_code(doc, data)
        if not session_id:
            return
        data = dict(doc.data or {})

    student_id = (data.get("studentId") or "").strip()
    if not student_id:
        return

    session = _load_session(session_id)
    if session is None:
        return

    if not _within_geofence(session.data or {}, data):
        data["status"] = "rejected"
        data["rejectionReason"] = "outside_geofence"
        doc.data = data
        doc.save(update_fields=["data", "updated_at"])
        return

    data["status"] = "accepted"
    data["sessionId"] = session_id
    data["listId"] = data.get("listId") or (session.data or {}).get("listId", "")
    data["awaitingSession"] = False
    doc.data = data
    doc.save(update_fields=["data", "updated_at"])

    record_id = f"{session_id}_{student_id}"
    record_payload = {
        "sessionId": session_id,
        "studentId": student_id,
        "listId": data.get("listId", ""),
        "course": data.get("course") or "—",
        "timestamp": data.get("capturedAt"),
        "latitude": data.get("latitude", 0),
        "longitude": data.get("longitude", 0),
        "verified": True,
        "present": True,
        "deviceId": data.get("deviceId", ""),
    }
    ApiDocument.objects.update_or_create(
        collection=RECORDS_COLLECTION,
        doc_id=record_id,
        defaults={"data": record_payload},
    )


def _link_session_by_code(doc: ApiDocument, data: dict) -> str:
    code = (data.get("sessionCodeRaw") or "").strip().upper()
    if not code:
        return ""
    session = (
        ApiDocument.objects.filter(
            collection=SESSIONS_COLLECTION,
            data__sessionCode=code,
            data__status="active",
        )
        .order_by("-updated_at")
        .first()
    )
    if session is None:
        return ""
    merged = dict(data)
    merged["sessionId"] = session.doc_id
    merged["listId"] = (session.data or {}).get("listId", "")
    merged["awaitingSession"] = False
    doc.data = merged
    doc.save(update_fields=["data", "updated_at"])
    return session.doc_id


def _load_session(session_id: str) -> ApiDocument | None:
    try:
        return ApiDocument.objects.get(
            collection=SESSIONS_COLLECTION,
            doc_id=session_id,
        )
    except ApiDocument.DoesNotExist:
        return None


def _within_geofence(session_data: dict, attempt_data: dict) -> bool:
    if session_data.get("remoteLearning"):
        return True
    if session_data.get("locationMetadataPending"):
        return True
    try:
        lat = float(attempt_data.get("latitude", 0))
        lng = float(attempt_data.get("longitude", 0))
        center_lat = float(session_data.get("latitude", 0))
        center_lng = float(session_data.get("longitude", 0))
        radius = float(session_data.get("radiusMeters", 50))
    except (TypeError, ValueError):
        return False
    if center_lat == 0 and center_lng == 0:
        return True
    distance = _haversine_meters(center_lat, center_lng, lat, lng)
    return distance <= radius + 15


def _haversine_meters(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    radius_earth = 6371000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lon2 - lon1)
    a = (
        math.sin(d_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    )
    return 2 * radius_earth * math.atan2(math.sqrt(a), math.sqrt(1 - a))
