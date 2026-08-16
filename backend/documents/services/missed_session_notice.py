"""Create missed-session notices (and pushes) when absent attendance rows are written."""

from __future__ import annotations

import logging
from datetime import timedelta

from django.utils import timezone

from documents.models import ApiDocument

logger = logging.getLogger(__name__)

RECORDS_COLLECTION = "attendance/records"
SESSIONS_COLLECTION = "attendance/sessions"
LISTS_COLLECTION = "attendance/lists"
NOTICES_COLLECTION = "notices"


def _is_absent(value) -> bool:
    return value is False or str(value).strip().lower() == "false"


def _was_absent(data: dict | None) -> bool:
    if not data:
        return False
    return _is_absent(data.get("present"))


def _load_session(session_id: str) -> dict | None:
    try:
        doc = ApiDocument.objects.get(
            collection=SESSIONS_COLLECTION,
            doc_id=session_id,
        )
        return doc.data or {}
    except ApiDocument.DoesNotExist:
        return None


def _load_list_title(list_id: str) -> str:
    if not list_id:
        return "Class session"
    try:
        doc = ApiDocument.objects.get(collection=LISTS_COLLECTION, doc_id=list_id)
        data = doc.data or {}
        title = str(data.get("title") or data.get("name") or "").strip()
        if title:
            return title
    except ApiDocument.DoesNotExist:
        pass
    return "Class session"


def maybe_enqueue_missed_session_notice(
    doc: ApiDocument,
    *,
    previous_data: dict | None = None,
) -> None:
    """Queue a missed-session notice when an absent attendance record is saved."""
    if doc.collection != RECORDS_COLLECTION:
        return

    data = doc.data or {}
    if not _is_absent(data.get("present")):
        return
    if _was_absent(previous_data):
        return

    student_id = str(data.get("studentId") or "").strip()
    session_id = str(data.get("sessionId") or "").strip()
    if not student_id or not session_id:
        return

    notice_id = f"missed_{session_id}_{student_id}"
    if ApiDocument.objects.filter(
        collection=NOTICES_COLLECTION,
        doc_id=notice_id,
    ).exists():
        return

    session = _load_session(session_id) or {}
    list_id = str(data.get("listId") or session.get("listId") or "").strip()
    list_title = _load_list_title(list_id)
    course = str(data.get("course") or "").strip()
    title = list_title if not course or course == "—" else f"{list_title} — {course}"
    body = (
        "You were marked absent for a class session. "
        "Open U-Panel to read the full notice."
    )

    now = timezone.now()
    notice_doc = ApiDocument.objects.create(
        collection=NOTICES_COLLECTION,
        doc_id=notice_id,
        data={
            "title": title,
            "body": body,
            "author": "U-Panel",
            "createdAt": now.isoformat(),
            "expiresAt": (now + timedelta(days=14)).isoformat(),
            "sendPush": True,
            "audience": "student",
            "targetStudentId": student_id,
            "targetListId": list_id,
            "sessionId": session_id,
            "kind": "missedSession",
        },
    )

    try:
        from notices.push_from_document import maybe_enqueue_notice_push

        maybe_enqueue_notice_push(notice_doc)
    except Exception:
        logger.exception(
            "Failed to enqueue missed-session push for record %s", doc.doc_id
        )
