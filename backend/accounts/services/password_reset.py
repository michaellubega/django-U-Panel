"""Send and confirm password-reset links."""

from __future__ import annotations

import hashlib
import secrets
from datetime import timedelta

from django.conf import settings
from django.core.cache import cache
from django.utils import timezone
from rest_framework.authtoken.models import Token

from accounts.models import PasswordResetToken, User

from .email_templates import password_reset_email_html
from .mailjet_email import MailDeliveryError, send_transactional_email

TOKEN_BYTES = 32
TOKEN_TTL = timedelta(hours=2)
REQUEST_COOLDOWN_SECONDS = 60
REQUEST_HOURLY_LIMIT = 5


class PasswordResetError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def queue_password_reset_email(email: str) -> None:
    """Rate-limit and enqueue a reset email when [email] matches a user."""
    normalized = (email or "").strip().lower()
    if not normalized:
        return
    if normalized.endswith("@staff.upanel.local"):
        return

    user = User.objects.filter(email__iexact=normalized).first()
    if user is None:
        return

    _enforce_rate_limit(user.pk)
    _record_request(user.pk)

    from accounts.tasks import send_password_reset_email_task

    send_password_reset_email_task.delay(user.pk)


def send_password_reset_email(user: User) -> None:
    raw_token = secrets.token_urlsafe(TOKEN_BYTES)
    token_hash = _hash_token(raw_token)
    PasswordResetToken.objects.filter(user=user, used_at__isnull=True).update(
        used_at=timezone.now()
    )
    PasswordResetToken.objects.create(
        user=user,
        token_hash=token_hash,
        expires_at=timezone.now() + TOKEN_TTL,
    )

    reset_url = (
        f"{settings.PUBLIC_API_URL.rstrip('/')}/api/auth/password-reset/confirm/"
        f"?token={raw_token}"
    )
    subject = "KIU-QA Department — Reset your U-Panel password"
    greeting = user.full_name.strip() if user.full_name else "U-Panel user"
    message = (
        f"Dear {greeting},\n\n"
        "We received a request to reset the password for your U-Panel account.\n\n"
        "Open this link to choose a new password:\n"
        f"{reset_url}\n\n"
        "This link expires in 2 hours.\n\n"
        "If you did not request a password reset, you can safely ignore this message.\n\n"
        "— KIU-QA Department\n"
    )
    html = password_reset_email_html(greeting=greeting, reset_url=reset_url)
    send_transactional_email(
        to_email=user.email,
        to_name=user.full_name or user.email,
        subject=subject,
        text_body=message,
        html_body=html,
    )


def reset_password_with_token(raw_token: str, new_password: str) -> User:
    token = (raw_token or "").strip()
    if not token:
        raise PasswordResetError("invalid-token", "Reset link is invalid.")

    password = (new_password or "").strip()
    if len(password) < 6:
        raise PasswordResetError(
            "weak-password",
            "Password must be at least 6 characters.",
        )

    token_hash = _hash_token(token)
    row = (
        PasswordResetToken.objects.select_related("user")
        .filter(token_hash=token_hash, used_at__isnull=True)
        .order_by("-created_at")
        .first()
    )
    if row is None:
        raise PasswordResetError(
            "invalid-token",
            "Reset link is invalid or already used.",
        )
    if row.expires_at < timezone.now():
        raise PasswordResetError(
            "expired-token",
            "Reset link has expired. Request a new one from the app.",
        )

    user = row.user
    user.set_password(password)
    user.save(update_fields=["password"])
    row.used_at = timezone.now()
    row.save(update_fields=["used_at"])
    PasswordResetToken.objects.filter(user=user, used_at__isnull=True).update(
        used_at=timezone.now()
    )
    Token.objects.filter(user=user).delete()
    return user


def user_for_password_reset_email(email: str) -> User | None:
    normalized = (email or "").strip().lower()
    if not normalized or normalized.endswith("@staff.upanel.local"):
        return None
    return User.objects.filter(email__iexact=normalized).first()


def _hash_token(raw: str) -> str:
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _enforce_rate_limit(user_id: int) -> None:
    try:
        cooldown_key = f"password_reset:cooldown:{user_id}"
        if cache.get(cooldown_key):
            raise PasswordResetError(
                "too-many-requests",
                "Please wait a minute before requesting another reset email.",
            )

        hour_key = f"password_reset:hour:{user_id}"
        count = cache.get(hour_key, 0)
        if count >= REQUEST_HOURLY_LIMIT:
            raise PasswordResetError(
                "too-many-requests",
                "Too many reset emails sent. Try again later.",
            )
    except PasswordResetError:
        raise
    except Exception:
        return


def _record_request(user_id: int) -> None:
    try:
        cache.set(
            f"password_reset:cooldown:{user_id}",
            1,
            REQUEST_COOLDOWN_SECONDS,
        )
        hour_key = f"password_reset:hour:{user_id}"
        try:
            cache.incr(hour_key)
        except ValueError:
            cache.set(hour_key, 1, 3600)
        else:
            if hasattr(cache, "touch"):
                cache.touch(hour_key, 3600)
    except Exception:
        return
