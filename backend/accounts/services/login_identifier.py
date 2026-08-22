"""Resolve login identifiers (email, staff ID, registration number) to User rows."""

from __future__ import annotations

import re

from accounts.models import User

_KIU_ADMIN_REG = re.compile(r"^KIU\d+[A-Z]$")
_KIU_STAFF_ID = re.compile(r"^KIU-\d{4}$")
_KIU_STAFF_COMPACT = re.compile(r"^KIU\d{4}$")
_DIGITS_ONLY = re.compile(r"^\d{4}$")
_SYNTHETIC_STAFF_DOMAIN = "staff.upanel.local"


def normalize_staff_number(raw: str) -> str | None:
    upper = raw.strip().upper().replace(" ", "")
    if _KIU_STAFF_ID.match(upper):
        return upper
    compact = upper.replace("-", "")
    if _KIU_STAFF_COMPACT.match(compact):
        return f"KIU-{compact[3:]}"
    if _DIGITS_ONLY.match(upper):
        return f"KIU-{upper}"
    return None


def synthetic_email_for_staff_number(staff_number: str) -> str | None:
    normalized = normalize_staff_number(staff_number)
    if normalized is None:
        return None
    local = normalized.replace("-", "").lower()
    return f"{local}@{_SYNTHETIC_STAFF_DOMAIN}"


def resolve_user_for_login(identifier: str) -> User | None:
    """Map a login field (email, KIU4235S, KIU-0001, …) to a User, if known."""
    raw = (identifier or "").strip()
    if not raw:
        return None

    if "@" in raw:
        email = raw.lower()
        return User.objects.filter(email__iexact=email).first()

    upper = raw.upper().replace(" ", "")

    user = User.objects.filter(registration_number__iexact=upper).first()
    if user is not None:
        return user

    staff_number = normalize_staff_number(upper)
    if staff_number is not None:
        user = User.objects.filter(staff_number__iexact=staff_number).first()
        if user is not None:
            return user
        synthetic = synthetic_email_for_staff_number(staff_number)
        if synthetic is not None:
            user = User.objects.filter(email__iexact=synthetic).first()
            if user is not None:
                return user

    if _KIU_ADMIN_REG.match(upper):
        return User.objects.filter(registration_number__iexact=upper).first()

    return None
