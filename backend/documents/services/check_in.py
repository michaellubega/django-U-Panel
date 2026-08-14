"""Check-in attempt processing (replaces Firebase Cloud Functions)."""

from __future__ import annotations

import math
from datetime import datetime, timezone as dt_timezone

from django.utils.dateparse import parse_datetime

from ..models import ApiDocument

CHECK_IN_COLLECTION = "attendance/check-in-attempts"
SESSIONS_COLLECTION = "attendance/sessions"
RECORDS_COLLECTION = "attendance/records"

GEOFENCE_BUFFER_METERS = 15


def maybe_process_check_in(doc: ApiDocument) -> None:
    if doc.collection != CHECK_IN_COLLECTION:
        return
    data = dict(doc.data or {})
    status = (data.get("status") or "pending").strip().lower()
    if status not in ("", "pending"):
        return

    session_id = (data.get("sessionId") or "").strip()
    awaiting = bool(data.get("awaitingSession"))
    if not session_id or awaiting:
        session_id = _link_session_by_code(doc, data)
        if not session_id:
            # Offline / lecturer-not-started-yet: keep pending for retry.
            if awaiting or (data.get("sessionCodeRaw") or "").strip():
                return
            _reject(doc, data, "session code not found")
            return
        data = dict(doc.data or {})

    student_id = (data.get("studentId") or "").strip()
    if not student_id:
        _reject(doc, data, "missing student id")
        return

    session = _load_session(session_id)
    if session is None:
        _reject(doc, data, "session does not match")
        return

    session_data = session.data or {}
    if not _within_session_time(session_data, data):
        _reject(doc, data, "outside session time")
        return

    if _device_used_by_other_student(session_id, student_id, data):
        _reject(doc, data, "device already used for another student")
        return

    if not _within_geofence(session_data, data):
        _reject(doc, data, "outside class location")
        return

    if _device_used_by_other_student(session_id, student_id, data):
        _reject(doc, data, "device already used for another student")
        return

    record_id = f"{session_id}_{student_id}"
    if _record_exists(record_id):
        data["status"] = "accepted"
        data["sessionId"] = session_id
        data["listId"] = data.get("listId") or session_data.get("listId", "")
        data["awaitingSession"] = False
        doc.data = data
        doc.save(update_fields=["data", "updated_at"])
        return

    data["status"] = "accepted"
    data["sessionId"] = session_id
    data["listId"] = data.get("listId") or session_data.get("listId", "")
    data["awaitingSession"] = False
    doc.data = data
    doc.save(update_fields=["data", "updated_at"])

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


def _reject(doc: ApiDocument, data: dict, reason: str) -> None:
    data["status"] = "rejected"
    data["rejectionReason"] = reason
    doc.data = data
    doc.save(update_fields=["data", "updated_at"])


def _record_exists(record_id: str) -> bool:
    return ApiDocument.objects.filter(
        collection=RECORDS_COLLECTION,
        doc_id=record_id,
    ).exists()


def _device_used_by_other_student(
    session_id: str, student_id: str, attempt_data: dict
) -> bool:
    device_id = (attempt_data.get("deviceId") or "").strip()
    if not device_id:
        return False
    sid = session_id.strip()
    if not sid:
        return False
    existing = ApiDocument.objects.filter(
        collection=RECORDS_COLLECTION,
        data__sessionId=sid,
        data__deviceId=device_id,
        data__present=True,
    ).exclude(data__studentId=student_id)
    return existing.exists()


def _link_session_by_code(doc: ApiDocument, data: dict) -> str:
    code = (data.get("sessionCodeRaw") or "").strip().upper()
    if not code:
        return ""
    session = (
        ApiDocument.objects.filter(
            collection=SESSIONS_COLLECTION,
            data__sessionCode__iexact=code,
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


def _parse_timestamp(value) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=dt_timezone.utc)
        return value
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(value / 1000.0, tz=dt_timezone.utc)
        except (OSError, OverflowError, ValueError):
            try:
                return datetime.fromtimestamp(value, tz=dt_timezone.utc)
            except (OSError, OverflowError, ValueError):
                return None
    text = str(value).strip()
    if not text:
        return None
    parsed = parse_datetime(text)
    if parsed is None:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=dt_timezone.utc)
    return parsed


def _within_session_time(session_data: dict, attempt_data: dict) -> bool:
    captured = _parse_timestamp(attempt_data.get("capturedAt"))
    if captured is None:
        return True
    start = _parse_timestamp(session_data.get("startTime"))
    end = _parse_timestamp(session_data.get("endTime"))
    if start is not None and captured < start:
        return False
    if end is not None:
        status = (session_data.get("status") or "").strip().lower()
        if captured > end and status != "active":
            return False
    return True


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
    if abs(lat) < 0.001 and abs(lng) < 0.001:
        return False
    distance = _haversine_meters(center_lat, center_lng, lat, lng)
    return distance <= radius + GEOFENCE_BUFFER_METERS


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
