"""OneSignal REST API client (replaces Firebase Cloud Messaging)."""

from __future__ import annotations

import logging
from typing import Iterable

import requests
from django.conf import settings

logger = logging.getLogger(__name__)

ONESIGNAL_API = "https://api.onesignal.com/notifications"


def onesignal_configured() -> bool:
    return bool(settings.ONESIGNAL_APP_ID and settings.ONESIGNAL_REST_API_KEY)


def send_push(
    *,
    headings: str,
    contents: str,
    tags: dict[str, str] | None = None,
    player_ids: Iterable[str] | None = None,
    data: dict | None = None,
) -> bool:
    """Send a push via OneSignal. Returns True when accepted by the API."""
    if not onesignal_configured():
        logger.debug("OneSignal not configured — push skipped")
        return False

    payload: dict = {
        "app_id": settings.ONESIGNAL_APP_ID,
        "headings": {"en": headings},
        "contents": {"en": contents},
    }
    if data:
        payload["data"] = data

    if player_ids:
        ids = [p.strip() for p in player_ids if p and str(p).strip()]
        if not ids:
            return False
        payload["include_player_ids"] = ids[:2000]
    elif tags:
        payload["filters"] = [
            {"field": "tag", "key": k, "relation": "=", "value": v}
            for k, v in tags.items()
            if k and v
        ]
        if not payload["filters"]:
            return False
    else:
        return False

    try:
        resp = requests.post(
            ONESIGNAL_API,
            json=payload,
            headers={
                "Authorization": f"Basic {settings.ONESIGNAL_REST_API_KEY}",
                "Content-Type": "application/json",
            },
            timeout=15,
        )
        if resp.status_code >= 400:
            logger.warning("OneSignal push failed: %s %s", resp.status_code, resp.text)
            return False
        return True
    except requests.RequestException as exc:
        logger.warning("OneSignal request error: %s", exc)
        return False


def tag_for_list(list_id: str) -> str:
    return f"list_{list_id.strip()}"


def tag_for_student(student_id: str) -> str:
    return f"stu_{student_id.strip()}"


def tag_for_lecturer(user_id: str) -> str:
    return f"lec_{user_id.strip()}"
