"""Mirror Django User rows into Firestore-shaped account documents."""

from __future__ import annotations

from accounts.models import User

from ..models import ApiDocument

USERS = "accounts/users"
ADMINS = "accounts/admins"
LECTURERS = "accounts/lecturers"
STUDENT_REGS = "accounts/student-registrations"
STAFF_NUMBERS = "accounts/staff-numbers"


def sync_user_profile(user: User) -> None:
    uid = str(user.pk)
    user_data = {
        "fullName": user.full_name,
        "email": user.email,
        "role": user.role,
        "isStudent": user.is_student,
        "registrationNumber": user.registration_number,
        "staffNumber": user.staff_number,
        "kiuAdminJobTitle": user.kiu_admin_job_title,
        "kiuAdminOnboardingComplete": user.kiu_admin_onboarding_complete,
        "emailVerified": user.email_verified,
    }
    reg = (user.registration_number or "").strip().upper()
    if user.is_student and not user.email_verified and reg:
        user_data["pendingRegistrationNumber"] = reg
    _upsert(USERS, uid, user_data)

    if user.is_administrator:
        if user.role == User.Role.KIU_ADMIN:
            admin_data = {
                "isKiuAdmin": True,
                "isAdmin": False,
                "fullName": user.full_name,
                "email": user.email,
                "staffNumber": user.staff_number,
                "kiuAdminJobTitle": user.kiu_admin_job_title,
                "adminRole": "kiu_administrator",
            }
            _upsert(ADMINS, uid, admin_data)
        else:
            admin_data = {
                "isAdmin": True,
                "fullName": user.full_name,
                "email": user.email,
                "staffNumber": user.staff_number,
            }
            if user.role == User.Role.QA_STAFF:
                admin_data["role"] = "qa_staff"
                admin_data["isQaStaff"] = True
            _upsert(ADMINS, uid, admin_data)
    else:
        _delete_if_exists(ADMINS, uid)

    if user.is_lecturer:
        _upsert(
            LECTURERS,
            uid,
            {
                "isLecturer": True,
                "fullName": user.full_name,
                "email": user.email,
                "staffNumber": user.staff_number,
            },
        )
    else:
        _delete_if_exists(LECTURERS, uid)

    if reg:
        _upsert(
            STUDENT_REGS,
            reg,
            {
                "registrationNumber": reg,
                "uid": uid,
                "email": user.email,
                "fullName": user.full_name,
                "emailVerifiedAtLink": user.email_verified,
            },
        )

    staff = (user.staff_number or "").strip().upper()
    if staff:
        _upsert(
            STAFF_NUMBERS,
            staff,
            {
                "staffNumber": staff,
                "uid": uid,
                "email": user.email,
                "fullName": user.full_name,
            },
        )


def _upsert(collection: str, doc_id: str, data: dict) -> None:
    ApiDocument.objects.update_or_create(
        collection=collection,
        doc_id=doc_id,
        defaults={"data": data},
    )


def _delete_if_exists(collection: str, doc_id: str) -> None:
    ApiDocument.objects.filter(collection=collection, doc_id=doc_id).delete()
