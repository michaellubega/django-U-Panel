"""Send and confirm signup email verification links."""

from __future__ import annotations

import hashlib
import secrets
from datetime import timedelta

from django.conf import settings
from django.core.cache import cache
from django.utils import timezone

from accounts.models import EmailVerificationToken, User
from documents.models import ApiDocument
from documents.services.user_sync import STUDENT_REGS, sync_user_profile

from .mailjet_email import MailDeliveryError, send_transactional_email
from .email_templates import verification_email_html

TOKEN_BYTES = 32
TOKEN_TTL = timedelta(hours=48)
RESEND_COOLDOWN_SECONDS = 60
RESEND_HOURLY_LIMIT = 5


class EmailVerificationError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def queue_verification_email(user: User) -> None:
    """Apply rate limits, then enqueue SMTP send so HTTP handlers return immediately."""
    if user.email_verified:
        return
    _enforce_rate_limit(user.pk)
    from accounts.tasks import send_verification_email_task

    send_verification_email_task.delay(user.pk)


def send_verification_email(user: User) -> None:
    if user.email_verified:
        return

    _enforce_rate_limit(user.pk)

    raw_token = secrets.token_urlsafe(TOKEN_BYTES)
    token_hash = _hash_token(raw_token)
    EmailVerificationToken.objects.filter(user=user, used_at__isnull=True).update(
        used_at=timezone.now()
    )
    EmailVerificationToken.objects.create(
        user=user,
        token_hash=token_hash,
        expires_at=timezone.now() + TOKEN_TTL,
    )

    verify_url = f"{settings.PUBLIC_API_URL.rstrip('/')}/api/auth/verify-email/?token={raw_token}"
    subject = "KIU-QA Department — Verify your U-Panel account"
    greeting = user.full_name.strip() if user.full_name else "Student"
    message = (
        f"Dear {greeting},\n\n"
        "You recently signed up for U-Panel, the KIU attendance and campus app.\n\n"
        "Please verify your school email by opening this link:\n"
        f"{verify_url}\n\n"
        "This link expires in 48 hours.\n\n"
        "If you did not request this, you can safely ignore this message.\n\n"
        "— KIU-QA Department\n"
    )
    html = verification_email_html(greeting=greeting, verify_url=verify_url)
    send_transactional_email(
        to_email=user.email,
        to_name=user.full_name or user.email,
        subject=subject,
        text_body=message,
        html_body=html,
    )
    _record_send(user.pk)


def verify_email_token(raw_token: str) -> User:
    token = (raw_token or "").strip()
    if not token:
        raise EmailVerificationError("invalid-token", "Verification link is invalid.")

    token_hash = _hash_token(token)
    row = (
        EmailVerificationToken.objects.select_related("user")
        .filter(token_hash=token_hash, used_at__isnull=True)
        .order_by("-created_at")
        .first()
    )
    if row is None:
        raise EmailVerificationError("invalid-token", "Verification link is invalid or already used.")
    if row.expires_at < timezone.now():
        raise EmailVerificationError("expired-token", "Verification link has expired. Request a new one in the app.")

    user = row.user
    row.used_at = timezone.now()
    row.save(update_fields=["used_at"])
    mark_user_email_verified(user)
    return user


def mark_user_email_verified(user: User) -> None:
    if user.email_verified:
        return
    user.email_verified = True
    user.save(update_fields=["email_verified"])
    _mark_student_registration_docs_verified(user)
    sync_user_profile(user)


def _mark_student_registration_docs_verified(user: User) -> None:
    uid = str(user.pk)
    qs = ApiDocument.objects.filter(collection=STUDENT_REGS, data__uid=uid)
    for doc in qs:
        data = dict(doc.data or {})
        data["emailVerifiedAtLink"] = True
        doc.data = data
        doc.save(update_fields=["data", "updated_at"])

    reg = (user.registration_number or "").strip().upper()
    if reg:
        try:
            doc = ApiDocument.objects.get(collection=STUDENT_REGS, doc_id=reg)
        except ApiDocument.DoesNotExist:
            return
        data = dict(doc.data or {})
        if data.get("uid") == uid:
            data["emailVerifiedAtLink"] = True
            doc.data = data
            doc.save(update_fields=["data", "updated_at"])


def _hash_token(raw: str) -> str:
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _enforce_rate_limit(user_id: int) -> None:
    try:
        cooldown_key = f"verify_email:cooldown:{user_id}"
        if cache.get(cooldown_key):
            raise EmailVerificationError(
                "too-many-requests",
                "Please wait a minute before requesting another verification email.",
            )

        hour_key = f"verify_email:hour:{user_id}"
        count = cache.get(hour_key, 0)
        if count >= RESEND_HOURLY_LIMIT:
            raise EmailVerificationError(
                "too-many-requests",
                "Too many verification emails sent. Try again later.",
            )
    except EmailVerificationError:
        raise
    except Exception:
        return


def _record_send(user_id: int) -> None:
    try:
        cache.set(f"verify_email:cooldown:{user_id}", 1, RESEND_COOLDOWN_SECONDS)
        hour_key = f"verify_email:hour:{user_id}"
        try:
            cache.incr(hour_key)
        except ValueError:
            cache.set(hour_key, 1, 3600)
        else:
            if hasattr(cache, "touch"):
                cache.touch(hour_key, 3600)
    except Exception:
        return
