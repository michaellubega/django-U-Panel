"""Role-based GET scoping for attendance ApiDocument collections.

Live attendance data lives in documents.ApiDocument (not SQL attendance.*).

Admin roles for this feature: administrator, qa_staff, and kiu_admin.
Flutter treats kiu_admin as full staff for attendance bulk watches
(see lib/features/attendance/data/attendance_repository.dart
sessionIdsForRtdRecordWatch — isKiuAdmin skips lecturer-limited RTD and uses
the same bulk path as admin/QA). Scoping kiu_admin like lecturers would break
the Flutter kiu_admin client, so they receive admin-wide attendance reads.

Service accounts (email *@upanel.internal, unusable password) are read-only:
POST/PATCH/DELETE on attendance/* are rejected.
"""

from __future__ import annotations

from django.db.models import Q, QuerySet

from accounts.models import User
from documents.models import ApiDocument

ATTENDANCE_COLLECTIONS: frozenset[str] = frozenset(
    {
        "attendance/lists",
        "attendance/sessions",
        "attendance/records",
        "attendance/check-in-attempts",
        "attendance/students",
        "attendance/sign-ins",
    }
)

ATTENDANCE_ADMIN_ROLES: frozenset[str] = frozenset(
    {
        User.Role.ADMINISTRATOR,
        User.Role.QA_STAFF,
        User.Role.KIU_ADMIN,
    }
)

ATTENDANCE_LECTURER_ROLES: frozenset[str] = frozenset(
    {
        User.Role.LECTURER,
    }
)

SERVICE_EMAIL_SUFFIX = "@upanel.internal"

# Student join flow queries sessions by code before any record exists.
_STUDENT_SESSION_LOOKUP_KEYS = frozenset({"sessionCode", "sessionCodeRaw"})


def is_attendance_collection(collection: str) -> bool:
    return collection in ATTENDANCE_COLLECTIONS


def is_attendance_api_service_user(user) -> bool:
    """Token-only service accounts created by create_attendance_api_token."""
    if user is None or not getattr(user, "is_authenticated", False):
        return False
    email = (getattr(user, "email", None) or "").strip().lower()
    if not email.endswith(SERVICE_EMAIL_SUFFIX):
        return False
    return not user.has_usable_password()


def is_attendance_admin(user) -> bool:
    return getattr(user, "role", None) in ATTENDANCE_ADMIN_ROLES


def is_attendance_lecturer_scope(user) -> bool:
    return getattr(user, "role", None) in ATTENDANCE_LECTURER_ROLES


def is_attendance_student(user) -> bool:
    return getattr(user, "role", None) == User.Role.STUDENT


def student_identity_values(user) -> set[str]:
    values: set[str] = set()
    pk = getattr(user, "pk", None)
    if pk is not None:
        values.add(str(pk))
    for attr in ("registration_number", "username", "email"):
        raw = (getattr(user, attr, None) or "").strip()
        if raw:
            values.add(raw)
    return values


def lecturer_owned_list_ids(user) -> set[str]:
    """List doc_ids owned by this lecturer (uid match or legacy whoTaught)."""
    uid = str(user.pk)
    owned = set(
        ApiDocument.objects.filter(
            collection="attendance/lists",
            data__lecturerUid=uid,
        ).values_list("doc_id", flat=True)
    )
    full_name = (getattr(user, "full_name", None) or "").strip()
    if full_name:
        # Legacy rows with no lecturerUid: match whoTaught display name only.
        for doc in ApiDocument.objects.filter(
            collection="attendance/lists",
            data__whoTaught=full_name,
        ).only("doc_id", "data"):
            raw_uid = (doc.data or {}).get("lecturerUid")
            if raw_uid is None or str(raw_uid).strip() == "":
                owned.add(doc.doc_id)
    return owned

def lecturer_session_ids(list_ids: set[str]) -> set[str]:
    if not list_ids:
        return set()
    return set(
        ApiDocument.objects.filter(
            collection="attendance/sessions",
            data__listId__in=list(list_ids),
        ).values_list("doc_id", flat=True)
    )


def student_record_refs(user) -> tuple[set[str], set[str]]:
    """Return (list_ids, session_ids) referenced by the student's own records."""
    identities = student_identity_values(user)
    if not identities:
        return set(), set()
    records = ApiDocument.objects.filter(
        collection="attendance/records",
        data__studentId__in=list(identities),
    )
    list_ids: set[str] = set()
    session_ids: set[str] = set()
    for data in records.values_list("data", flat=True):
        if not isinstance(data, dict):
            continue
        lid = data.get("listId")
        sid = data.get("sessionId")
        if lid is not None and str(lid).strip():
            list_ids.add(str(lid).strip())
        if sid is not None and str(sid).strip():
            session_ids.add(str(sid).strip())
    return list_ids, session_ids


def apply_attendance_get_scope(
    qs: QuerySet,
    user,
    collection: str,
    query_params=None,
) -> QuerySet:
    """Restrict a collection queryset for GET list/retrieve scoping."""
    if not is_attendance_collection(collection):
        return qs
    if is_attendance_admin(user):
        return qs

    if is_attendance_lecturer_scope(user):
        return _scope_lecturer_qs(qs, user, collection)

    if is_attendance_student(user):
        return _scope_student_qs(qs, user, collection, query_params)

    # Unknown / unexpected roles: deny attendance reads.
    return qs.none()


def document_allowed_on_get(doc: ApiDocument, user) -> bool:
    """Return True if a single document may be returned on GET retrieve."""
    if not is_attendance_collection(doc.collection):
        return True
    if is_attendance_admin(user):
        return True
    # Flutter join watches refresh session docs by id after a sessionCode lookup,
    # often before the student has a record. Allow single-doc session GET.
    if is_attendance_student(user) and doc.collection == "attendance/sessions":
        return True
    scoped = apply_attendance_get_scope(
        ApiDocument.objects.filter(pk=doc.pk),
        user,
        doc.collection,
    )
    return scoped.exists()

def _scope_lecturer_qs(qs: QuerySet, user, collection: str) -> QuerySet:
    list_ids = lecturer_owned_list_ids(user)
    session_ids = lecturer_session_ids(list_ids)

    if collection == "attendance/lists":
        return qs.filter(doc_id__in=list(list_ids)) if list_ids else qs.none()

    if collection == "attendance/sessions":
        if not list_ids:
            return qs.none()
        return qs.filter(data__listId__in=list(list_ids))

    if collection in {"attendance/records", "attendance/check-in-attempts"}:
        if not list_ids and not session_ids:
            return qs.none()
        q = Q()
        if list_ids:
            q |= Q(data__listId__in=list(list_ids))
        if session_ids:
            q |= Q(data__sessionId__in=list(session_ids))
        return qs.filter(q)

    if collection in {"attendance/students", "attendance/sign-ins"}:
        # Not part of lecturer export scope; keep empty for API tokens.
        return qs.none()

    return qs.none()


def _scope_student_qs(qs: QuerySet, user, collection: str, query_params) -> QuerySet:
    identities = student_identity_values(user)
    list_ids, session_ids = student_record_refs(user)

    if collection in {"attendance/records", "attendance/check-in-attempts"}:
        if not identities:
            return qs.none()
        return qs.filter(data__studentId__in=list(identities))

    if collection == "attendance/sessions":
        # Flutter join: students look up sessions by code before any record exists.
        params = query_params or {}
        if any(str(params.get(k) or "").strip() for k in _STUDENT_SESSION_LOOKUP_KEYS):
            return qs
        if not session_ids:
            return qs.none()
        return qs.filter(doc_id__in=list(session_ids))

    if collection == "attendance/lists":
        if not list_ids:
            return qs.none()
        return qs.filter(doc_id__in=list(list_ids))

    if collection == "attendance/students":
        if not identities:
            return qs.none()
        return qs.filter(
            Q(doc_id__in=list(identities)) | Q(data__studentId__in=list(identities))
        )

    if collection == "attendance/sign-ins":
        if not identities:
            return qs.none()
        return qs.filter(data__studentId__in=list(identities))

    return qs.none()
