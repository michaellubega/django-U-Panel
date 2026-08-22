"""Map request paths to (collection, doc_id) using known collection names."""

from __future__ import annotations

# Longest paths first so `attendance/check-in-attempts` wins over `attendance`.
KNOWN_COLLECTIONS: tuple[str, ...] = tuple(
    sorted(
        (
            "attendance/check-in-attempts",
            "accounts/student-registrations",
            "accounts/staff-numbers",
            "attendance/sessions",
            "attendance/records",
            "attendance/students",
            "attendance/sign-ins",
            "attendance/lists",
            "attendance/health",
            "campus/presence",
            "accounts/lecturers",
            "accounts/admins",
            "accounts/users",
            "notices",
        ),
        key=len,
        reverse=True,
    )
)


def split_resource_path(resource_path: str) -> tuple[str, str | None]:
    """Return (collection, doc_id). doc_id is None for collection list requests."""
    path = (resource_path or "").strip("/")
    if not path:
        return "", None

    for collection in KNOWN_COLLECTIONS:
        if path == collection:
            return collection, None
        prefix = f"{collection}/"
        if path.startswith(prefix):
            doc_id = path[len(prefix) :]
            if doc_id:
                return collection, doc_id

    parts = path.split("/")
    if len(parts) == 1:
        return parts[0], None
    return "/".join(parts[:-1]), parts[-1]
