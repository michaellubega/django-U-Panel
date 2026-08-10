"""Send OneSignal pushes for notices stored in ApiDocument (replaces orphaned Notice ORM path)."""

from __future__ import annotations

import logging
import re
from datetime import datetime
from typing import Any

from django.utils import timezone
from django.utils.dateparse import parse_datetime

from upanel.services.onesignal import (
    send_push,
    tag_for_kiu_admins,
    tag_for_lecturer,
    tag_for_list,
    tag_for_student,
)

logger = logging.getLogger(__name__)

K_PUSH_ALL_NOTICES_TAG = "all_notices"


def sanitize_push_tag_segment(raw: str) -> str:
    return re.sub(r"[^a-zA-Z0-9\-_.~%]", "_", raw.strip())


def _parse_notice_time(raw: Any) -> datetime | None:
    if raw is None:
        return None
    if isinstance(raw, (int, float)):
        try:
            return timezone.datetime.fromtimestamp(float(raw) / 1000.0, tz=timezone.utc)
        except (OSError, OverflowError, ValueError):
            return None
    text = str(raw).strip()
    if not text:
        return None
    parsed = parse_datetime(text)
    if parsed is None:
        return None
    if timezone.is_naive(parsed):
        return timezone.make_aware(parsed, timezone.utc)
    return parsed


def notice_data_is_live(data: dict, *, now: datetime | None = None) -> bool:
    at = now or timezone.now()
    scheduled = _parse_notice_time(data.get("scheduledFor"))
    if scheduled is None:
        return True
    return scheduled <= at


def notice_push_already_sent(data: dict) -> bool:
    return bool(str(data.get("pushSentAt") or "").strip())


def push_tags_for_notice(data: dict) -> dict[str, str] | None:
    audience = str(data.get("audience") or "").strip().lower()
    kind = str(data.get("kind") or "").strip().lower()

    if kind == "lecturertakeattendance":
        uid = str(data.get("targetLecturerUid") or "").strip()
        if uid:
            return {tag_for_lecturer(uid): "true"}
        return None

    if audience == "kiuadmins":
        return {tag_for_kiu_admins(): "true"}

    if audience == "classlist":
        list_id = str(data.get("targetListId") or "").strip()
        if list_id:
            return {tag_for_list(list_id): "true"}
        return None

    if audience == "student":
        student_id = str(data.get("targetStudentId") or "").strip()
        if student_id:
            return {tag_for_student(student_id): "true"}
        return None

    return {K_PUSH_ALL_NOTICES_TAG: "true"}


def push_copy_for_notice(data: dict) -> tuple[str, str]:
    title = str(data.get("title") or "U-Panel notice").strip() or "U-Panel notice"
    body = str(data.get("body") or "").strip()
    kind = str(data.get("kind") or "").strip().lower()

    if kind == "sessioncode":
        return title, "Your class is ready. Open the app."
    if kind == "lecturertakeattendance":
        if not body:
            body = (
                "Your class is ready — open U-Panel and start the attendance session."
            )
        return title, body[:500]
    if kind == "qastartattendance":
        if not body:
            body = (
                "A lecturer has not opened attendance 1 hour 30 minutes after lesson time. "
                "Open U-Panel to start the session."
            )
        return title, body[:500]
    if kind == "missedsession":
        if not body:
            body = (
                "You were marked absent for a class session. Open the app to read the full notice."
            )
        return title, body[:500]

    if not body:
        body = title
    return title, body[:500]


def push_data_payload(doc_id: str, data: dict) -> dict[str, str]:
    payload: dict[str, str] = {
        "noticeId": doc_id,
        "kind": str(data.get("kind") or ""),
    }
    session_code = str(data.get("sessionCode") or "").strip()
    if session_code:
        payload["sessionCode"] = session_code
    session_id = str(data.get("sessionId") or "").strip()
    if session_id:
        payload["sessionId"] = session_id
    return payload


def send_notice_push(doc_id: str, data: dict) -> bool:
    if not data.get("sendPush"):
        return False
    if notice_push_already_sent(data):
        return False
    if not notice_data_is_live(data):
        return False

    tags = push_tags_for_notice(data)
    if not tags:
        return False

    title, body = push_copy_for_notice(data)
    return send_push(
        headings=title,
        contents=body or title,
        tags=tags,
        data=push_data_payload(doc_id, data),
    )


def mark_notice_push_sent(doc) -> None:
    """Persist pushSentAt on the ApiDocument to avoid duplicate delivery."""
    from documents.models import ApiDocument

    if not isinstance(doc, ApiDocument):
        return
    merged = dict(doc.data or {})
    if notice_push_already_sent(merged):
        return
    merged["pushSentAt"] = timezone.now().isoformat()
    doc.data = merged
    doc.save(update_fields=["data", "updated_at"])


def maybe_enqueue_notice_push(doc) -> None:
    """Queue a push when a live notice document is written."""
    if doc.collection != "notices":
        return
    data = doc.data or {}
    if not data.get("sendPush"):
        return
    if notice_push_already_sent(data):
        return
    if not notice_data_is_live(data):
        return

    from notices.tasks import push_notice_document

    push_notice_document.delay(doc.doc_id)
