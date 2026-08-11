"""OneSignal REST API client (replaces Firebase Cloud Messaging)."""

from __future__ import annotations

import logging
import re
from typing import Iterable

import requests
from django.conf import settings

logger = logging.getLogger(__name__)

ONESIGNAL_API = "https://api.onesignal.com/notifications"


def onesignal_configured() -> bool:
    return bool(settings.ONESIGNAL_APP_ID and settings.ONESIGNAL_REST_API_KEY)


def onesignal_authorization_header(api_key: str) -> str:
    """Build the Authorization header for OneSignal REST API requests."""
    key = (api_key or "").strip()
    if not key:
        return ""
    lower = key.lower()
    if lower.startswith("basic ") or lower.startswith("key "):
        return key
    return f"Key {key}"


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
        logger.warning(
            "OneSignal not configured — set ONESIGNAL_APP_ID and ONESIGNAL_REST_API_KEY "
            "in .env.production, then restart web/worker/beat."
        )
        return False

    payload: dict = {
        "app_id": settings.ONESIGNAL_APP_ID,
        "target_channel": "push",
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
                "Authorization": onesignal_authorization_header(
                    settings.ONESIGNAL_REST_API_KEY
                ),
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
    segment = re.sub(r"[^a-zA-Z0-9\-_.~%]", "_", list_id.strip())
    return f"list_{segment}"


def tag_for_student(student_id: str) -> str:
    segment = re.sub(r"[^a-zA-Z0-9\-_.~%]", "_", student_id.strip())
    return f"stu_{segment}"


def tag_for_lecturer(user_id: str) -> str:
    segment = re.sub(r"[^a-zA-Z0-9\-_.~%]", "_", user_id.strip())
    return f"lec_{segment}"


def tag_for_kiu_admins() -> str:
    return "kiu_admins"
