"""Dedicated attendance export API for external readers (e.g. KIU-QAAT)."""

from __future__ import annotations

from datetime import datetime

from django.utils.dateparse import parse_date, parse_datetime
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from documents.attendance_scope import apply_attendance_get_scope
from documents.filters import serialize_document
from documents.models import ApiDocument

EXPORT_MAX_LIMIT = 5000
EXPORT_DEFAULT_LIMIT = 1000


class AttendanceExportView(APIView):
    """GET /api/attendance/export/ — role-scoped attendance dump for QAAT."""

    permission_classes = [IsAuthenticated]

    def get(self, request):
        try:
            limit = int(request.query_params.get("limit", EXPORT_DEFAULT_LIMIT))
        except (TypeError, ValueError):
            limit = EXPORT_DEFAULT_LIMIT
        limit = max(1, min(limit, EXPORT_MAX_LIMIT))

        try:
            offset = int(request.query_params.get("offset", 0))
        except (TypeError, ValueError):
            offset = 0
        offset = max(0, offset)

        records_qs = ApiDocument.objects.filter(collection="attendance/records")
        records_qs = apply_attendance_get_scope(
            records_qs, request.user, "attendance/records"
        )

        list_id = (request.query_params.get("list_id") or "").strip()
        session_id = (request.query_params.get("session_id") or "").strip()
        student_id = (request.query_params.get("student_id") or "").strip()
        if list_id:
            records_qs = records_qs.filter(data__listId=list_id)
        if session_id:
            records_qs = records_qs.filter(data__sessionId=session_id)
        if student_id:
            records_qs = records_qs.filter(data__studentId=student_id)

        date_from = _parse_bound(request.query_params.get("from"))
        date_to = _parse_bound(request.query_params.get("to"), end_of_day=True)
        if date_from is not None or date_to is not None:
            records_qs = _filter_records_by_timestamp(records_qs, date_from, date_to)

        # Prefer timestamp ordering; fall back to updated_at for missing values.
        records = list(records_qs.order_by("-updated_at", "doc_id"))
        records.sort(key=_record_timestamp_sort_key, reverse=True)
        page = records[offset : offset + limit]

        related_list_ids: set[str] = set()
        related_session_ids: set[str] = set()
        for doc in page:
            data = doc.data or {}
            lid = data.get("listId")
            sid = data.get("sessionId")
            if lid is not None and str(lid).strip():
                related_list_ids.add(str(lid).strip())
            if sid is not None and str(sid).strip():
                related_session_ids.add(str(sid).strip())
            # Also include explicit query filters so related docs return even
            # when the page of records is empty.
        if list_id:
            related_list_ids.add(list_id)
        if session_id:
            related_session_ids.add(session_id)

        lists_qs = ApiDocument.objects.filter(collection="attendance/lists")
        lists_qs = apply_attendance_get_scope(
            lists_qs, request.user, "attendance/lists"
        )
        if related_list_ids:
            lists_qs = lists_qs.filter(doc_id__in=list(related_list_ids))
        else:
            lists_qs = lists_qs.none()

        sessions_qs = ApiDocument.objects.filter(collection="attendance/sessions")
        sessions_qs = apply_attendance_get_scope(
            sessions_qs, request.user, "attendance/sessions"
        )
        if related_session_ids:
            sessions_qs = sessions_qs.filter(doc_id__in=list(related_session_ids))
        else:
            sessions_qs = sessions_qs.none()

        return Response(
            {
                "lists": [serialize_document(d) for d in lists_qs],
                "sessions": [serialize_document(d) for d in sessions_qs],
                "records": [serialize_document(d) for d in page],
                "count": len(records),
                "limit": limit,
                "offset": offset,
            }
        )


def _parse_bound(raw, *, end_of_day: bool = False):
    text = (raw or "").strip()
    if not text:
        return None
    dt = parse_datetime(text)
    if dt is not None:
        return dt
    d = parse_date(text)
    if d is None:
        return None
    if end_of_day:
        return datetime(d.year, d.month, d.day, 23, 59, 59, 999999)
    return datetime(d.year, d.month, d.day, 0, 0, 0)


def _filter_records_by_timestamp(qs, date_from, date_to):
    """Filter in Python when timestamps are heterogeneous ISO strings in JSON."""
    matched_pks = []
    for doc in qs.only("pk", "data"):
        ts = _coerce_timestamp((doc.data or {}).get("timestamp"))
        if ts is None:
            continue
        if date_from is not None and ts < date_from:
            continue
        if date_to is not None and ts > date_to:
            continue
        matched_pks.append(doc.pk)
    return qs.filter(pk__in=matched_pks)


def _coerce_timestamp(raw):
    if raw is None:
        return None
    if isinstance(raw, datetime):
        return raw.replace(tzinfo=None) if raw.tzinfo else raw
    text = str(raw).strip()
    if not text:
        return None
    dt = parse_datetime(text)
    if dt is not None:
        return dt.replace(tzinfo=None) if dt.tzinfo else dt
    d = parse_date(text)
    if d is not None:
        return datetime(d.year, d.month, d.day)
    return None


def _record_timestamp_sort_key(doc: ApiDocument):
    ts = _coerce_timestamp((doc.data or {}).get("timestamp"))
    if ts is not None:
        return ts
    # updated_at is timezone-aware; normalize for comparison with naive ts.
    updated = doc.updated_at
    if updated is not None and updated.tzinfo is not None:
        return updated.replace(tzinfo=None)
    return updated or datetime.min
