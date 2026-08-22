"""U-Panel Django admin branding, navigation, and dashboard metrics."""

from __future__ import annotations

from datetime import timedelta

from django.conf import settings
from django.contrib import admin
from django.db import connection
from django.db.models import Count
from django.utils import timezone


def _count_by_collection(collection: str) -> int:
    from documents.models import ApiDocument

    return ApiDocument.objects.filter(collection=collection).count()


def _top_collections(limit: int = 8) -> list[dict]:
    from documents.models import ApiDocument

    rows = (
        ApiDocument.objects.values("collection")
        .annotate(count=Count("id"))
        .order_by("-count")[:limit]
    )
    return [{"name": row["collection"], "count": row["count"]} for row in rows]


def get_system_info() -> dict:
    cache_backend = settings.CACHES.get("default", {}).get("BACKEND", "")
    redis_on = "redis" in cache_backend.lower()
    email_backend = getattr(settings, "EMAIL_BACKEND", "")
    return {
        "debug": settings.DEBUG,
        "database": connection.vendor,
        "redis": redis_on,
        "email": email_backend.rsplit(".", 1)[-1].replace("EmailBackend", " email"),
        "public_api_url": getattr(settings, "PUBLIC_API_URL", ""),
        "timezone": str(settings.TIME_ZONE),
    }


def get_dashboard_context() -> dict:
    from accounts.models import EmailVerificationToken, PushDevice, StudentRegistration, User

    now = timezone.now()
    week_ago = now - timedelta(days=7)
    day_ago = now - timedelta(days=1)

    users = User.objects.all()
    role_rows = users.values("role").annotate(count=Count("id")).order_by("role")
    role_counts = {row["role"]: row["count"] for row in role_rows}

    students = users.filter(role=User.Role.STUDENT)
    staff_roles = (
        User.Role.LECTURER,
        User.Role.QA_STAFF,
        User.Role.ADMINISTRATOR,
        User.Role.KIU_ADMIN,
    )

    pending_tokens = EmailVerificationToken.objects.filter(
        used_at__isnull=True,
        expires_at__gt=now,
    ).count()
    expired_tokens = EmailVerificationToken.objects.filter(
        used_at__isnull=True,
        expires_at__lte=now,
    ).count()

    verified = students.filter(email_verified=True).count()
    student_total = role_counts.get(User.Role.STUDENT, 0)
    verify_pct = round((verified / student_total) * 100) if student_total else 0

    return {
        "stats": {
            "total_users": users.count(),
            "students": student_total,
            "lecturers": role_counts.get(User.Role.LECTURER, 0),
            "qa_staff": role_counts.get(User.Role.QA_STAFF, 0),
            "administrators": role_counts.get(User.Role.ADMINISTRATOR, 0)
            + role_counts.get(User.Role.KIU_ADMIN, 0),
            "staff_total": users.filter(role__in=staff_roles).count(),
            "verified_students": verified,
            "pending_email": students.filter(email_verified=False).count(),
            "verify_pct": verify_pct,
            "inactive_users": users.filter(is_active=False).count(),
            "registrations_claimed": StudentRegistration.objects.count(),
            "new_users_week": users.filter(date_joined__gte=week_ago).count(),
            "new_users_day": users.filter(date_joined__gte=day_ago).count(),
            "push_devices": PushDevice.objects.count(),
            "pending_verification_tokens": pending_tokens,
            "expired_verification_tokens": expired_tokens,
            "attendance_sessions": _count_by_collection("attendance/sessions"),
            "attendance_lists": _count_by_collection("attendance/lists"),
            "attendance_records": _count_by_collection("attendance/records"),
            "notices": _count_by_collection("notices"),
            "documents_total": _count_by_collection("accounts/users"),
        },
        "top_collections": _top_collections(),
        "recent_users": users.order_by("-date_joined")[:10],
        "system": get_system_info(),
        "role_labels": dict(User.Role.choices),
    }


def configure_admin_site() -> None:
    site = admin.site
    site.site_header = "U-Panel System Admin"
    site.site_title = "U-Panel Admin"
    site.index_title = "Operations center"

    original_index = site.index
    original_each_context = site.each_context

    def index_with_dashboard(request, extra_context=None):
        context = get_dashboard_context()
        if extra_context:
            context.update(extra_context)
        return original_index(request, context)

    def each_context_with_system(request):
        context = original_each_context(request)
        context["upanel_system"] = get_system_info()
        return context

    site.index = index_with_dashboard
    site.each_context = each_context_with_system
