"""Send transactional mail via Mailjet REST API (preferred) or Django SMTP."""

from __future__ import annotations

import logging
import re
from email.utils import parseaddr

import requests
from django.conf import settings
from django.core.mail import send_mail
from requests.auth import HTTPBasicAuth

logger = logging.getLogger(__name__)

MAILJET_SEND_URL = "https://api.mailjet.com/v3.1/send"


class MailDeliveryError(Exception):
    def __init__(self, message: str, *, status_code: int | None = None):
        super().__init__(message)
        self.message = message
        self.status_code = status_code


def parse_from_address(raw: str | None = None) -> tuple[str, str]:
    """Return (display_name, email) for outbound mail."""
    name = getattr(settings, "EMAIL_FROM_NAME", "").strip()
    address = getattr(settings, "EMAIL_FROM_ADDRESS", "").strip().lower()
    if name and address:
        return name, address

    source = (raw or getattr(settings, "DEFAULT_FROM_EMAIL", "") or "").strip()
    parsed_name, parsed_email = parseaddr(source)
    email = parsed_email.strip().lower()
    if not email:
        raise MailDeliveryError(f"Invalid from address: {source!r}")
    return parsed_name.strip() or "KIU-QA Department", email


def format_from_header(name: str, email: str) -> str:
    safe_name = name.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{safe_name}" <{email}>'


def send_transactional_email(
    *,
    to_email: str,
    subject: str,
    text_body: str,
    html_body: str | None = None,
    to_name: str = "",
) -> None:
    recipient = (to_email or "").strip().lower()
    if not recipient:
        raise MailDeliveryError("Recipient email is required.")

    from_name, from_email = parse_from_address()
    from_header = format_from_header(from_name, from_email)
    html = html_body or _text_to_basic_html(text_body)

    if getattr(settings, "MAILJET_API_KEY", "") and getattr(settings, "MAILJET_SECRET_KEY", ""):
        _send_mailjet_api(
            from_email=from_email,
            from_name=from_name,
            from_header=from_header,
            to_email=recipient,
            to_name=to_name.strip() or recipient,
            subject=subject,
            text_body=text_body,
            html_body=html,
        )
        return

    send_mail(
        subject,
        text_body,
        from_header,
        [recipient],
        fail_silently=False,
        html_message=html,
    )


def _send_mailjet_api(
    *,
    from_email: str,
    from_name: str,
    from_header: str,
    to_email: str,
    to_name: str,
    subject: str,
    text_body: str,
    html_body: str,
) -> None:
    payload = {
        "Messages": [
            {
                "From": {"Email": from_email, "Name": from_name},
                "To": [{"Email": to_email, "Name": to_name}],
                "Subject": subject,
                "TextPart": text_body,
                "HTMLPart": html_body,
                "Headers": {
                    "Reply-To": from_header,
                },
                "CustomCampaign": "upanel-transactional",
            }
        ]
    }
    try:
        response = requests.post(
            MAILJET_SEND_URL,
            json=payload,
            auth=HTTPBasicAuth(settings.MAILJET_API_KEY, settings.MAILJET_SECRET_KEY),
            timeout=30,
        )
    except requests.RequestException as exc:
        logger.exception("Mailjet request failed for %s", to_email)
        raise MailDeliveryError(f"Could not reach Mailjet: {exc}") from exc

    if response.status_code >= 400:
        detail = _extract_mailjet_error(response)
        logger.error(
            "Mailjet rejected email to %s (HTTP %s): %s",
            to_email,
            response.status_code,
            detail,
        )
        raise MailDeliveryError(detail, status_code=response.status_code)

    try:
        body = response.json()
        message = (body.get("Messages") or [{}])[0]
        status = message.get("Status", "")
        errors = message.get("Errors")
        if errors:
            detail = "; ".join(
                e.get("ErrorMessage", str(e)) for e in errors if isinstance(e, dict)
            )
            logger.error("Mailjet send error for %s: %s", to_email, detail)
            raise MailDeliveryError(detail or "Mailjet rejected the message.")
        logger.info(
            "Mailjet accepted email to %s (status=%s, message_id=%s)",
            to_email,
            status,
            _first_message_id(message),
        )
    except MailDeliveryError:
        raise
    except Exception:
        logger.info("Mailjet accepted email to %s (HTTP %s)", to_email, response.status_code)


def _extract_mailjet_error(response: requests.Response) -> str:
    try:
        data = response.json()
    except ValueError:
        return response.text[:500] or f"Mailjet HTTP {response.status_code}"
    if isinstance(data, dict):
        if data.get("ErrorMessage"):
            return str(data["ErrorMessage"])
        messages = data.get("Messages")
        if isinstance(messages, list) and messages:
            errors = messages[0].get("Errors")
            if isinstance(errors, list) and errors:
                return "; ".join(
                    e.get("ErrorMessage", str(e)) for e in errors if isinstance(e, dict)
                )
    return response.text[:500] or f"Mailjet HTTP {response.status_code}"


def _first_message_id(message: dict) -> str | None:
    to_list = message.get("To")
    if isinstance(to_list, list) and to_list:
        mid = to_list[0].get("MessageID")
        return str(mid) if mid is not None else None
    return None


def _text_to_basic_html(text: str) -> str:
    escaped = (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )
    linked = escaped
    for match in re.finditer(r"https?://[^\s<]+", linked):
        url = match.group(0)
        linked = linked.replace(url, f'<a href="{url}">{url}</a>', 1)
    return (
        "<html><body style=\"font-family:system-ui,sans-serif;line-height:1.5;\">"
        f"<pre style=\"white-space:pre-wrap;font-family:inherit;\">{linked}</pre>"
        "</body></html>"
    )
