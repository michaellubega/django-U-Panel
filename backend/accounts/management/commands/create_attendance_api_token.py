"""
Create / rotate long-lived DRF tokens for reading U-Panel attendance.

Contabo (production) example:

  docker compose -f docker-compose.prod.yml --env-file .env.production exec web \\
    python manage.py create_attendance_api_token --role admin --create-service-user --rotate

Other examples:

  python manage.py create_attendance_api_token --role student --user-id 12
  python manage.py create_attendance_api_token --role lecturer --email a@b.com
  python manage.py create_attendance_api_token --role admin --email a@b.com --rotate
"""

from __future__ import annotations

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from rest_framework.authtoken.models import Token

from accounts.models import User

SERVICE_EMAIL_DOMAIN = "upanel.internal"

ROLE_CHOICES = ("student", "lecturer", "admin")

# Map CLI --role to User.role values.
ROLE_TO_USER_ROLE = {
    "student": User.Role.STUDENT,
    "lecturer": User.Role.LECTURER,
    "admin": User.Role.ADMINISTRATOR,
}

# Roles that satisfy each CLI --role (existing users may be qa_staff for admin).
ROLE_ACCEPT = {
    "student": {User.Role.STUDENT},
    "lecturer": {User.Role.LECTURER},
    "admin": {User.Role.ADMINISTRATOR, User.Role.QA_STAFF},
}

SCOPE_BLURBS = {
    "student": (
        "attendance/records + attendance/check-in-attempts "
        "(studentId in {registration_number, pk, username}); "
        "attendance/lists + attendance/sessions referenced by those records"
    ),
    "lecturer": (
        "attendance/lists (lecturerUid=pk or legacy whoTaught); "
        "attendance/sessions for those lists; "
        "attendance/records + check-in-attempts for those lists/sessions"
    ),
    "admin": (
        "all attendance/lists, sessions, records, check-in-attempts, "
        "students, sign-ins (administrator / qa_staff / kiu_admin)"
    ),
}


class Command(BaseCommand):
    help = (
        "Create or rotate a DRF Token for reading attendance via "
        "Authorization: Token <key>. "
        "Contabo: docker compose -f docker-compose.prod.yml "
        "--env-file .env.production exec web "
        "python manage.py create_attendance_api_token "
        "--role admin --create-service-user --rotate"
    )

    def add_arguments(self, parser):
        parser.add_argument(
            "--role",
            choices=ROLE_CHOICES,
            required=True,
            help="Token scope role: student | lecturer | admin",
        )
        parser.add_argument("--user-id", type=int, default=None)
        parser.add_argument("--email", type=str, default=None)
        parser.add_argument(
            "--create-service-user",
            action="store_true",
            help=(
                f"Create attendance-api-{{role}}@{SERVICE_EMAIL_DOMAIN} "
                "with an unusable password (token-only)."
            ),
        )
        parser.add_argument(
            "--rotate",
            action="store_true",
            help="Delete existing tokens for the user, then create a new one.",
        )

    @transaction.atomic
    def handle(self, *args, **options):
        role = options["role"]
        user = self._resolve_user(
            role=role,
            user_id=options.get("user_id"),
            email=options.get("email"),
            create_service=options["create_service_user"],
        )

        if options["rotate"]:
            Token.objects.filter(user=user).delete()

        token, _created = Token.objects.get_or_create(user=user)

        # Print ONLY the requested fields (no extra logging of the secret).
        self.stdout.write(f"role={role}")
        self.stdout.write(f"user_id={user.pk}")
        self.stdout.write(f"email={user.email}")
        self.stdout.write(f"token={token.key}")
        self.stdout.write(f"header=Authorization: Token {token.key}")
        self.stdout.write(f"scopes={SCOPE_BLURBS[role]}")

    def _resolve_user(self, *, role: str, user_id, email, create_service: bool) -> User:
        if create_service:
            if user_id is not None or email:
                raise CommandError(
                    "Use --create-service-user alone (do not pass --user-id/--email)."
                )
            return self._get_or_create_service_user(role)

        if user_id is None and not email:
            raise CommandError(
                "Provide --user-id or --email, or pass --create-service-user."
            )
        if user_id is not None and email:
            raise CommandError("Pass only one of --user-id or --email.")

        if user_id is not None:
            try:
                user = User.objects.get(pk=user_id)
            except User.DoesNotExist as exc:
                raise CommandError(f"No user with id={user_id}.") from exc
        else:
            email_norm = (email or "").strip().lower()
            try:
                user = User.objects.get(email__iexact=email_norm)
            except User.DoesNotExist as exc:
                raise CommandError(f"No user with email={email_norm}.") from exc
            except User.MultipleObjectsReturned as exc:
                raise CommandError(
                    f"Multiple users match email={email_norm}; use --user-id."
                ) from exc

        accepted = ROLE_ACCEPT[role]
        if user.role not in accepted:
            raise CommandError(
                f"User id={user.pk} email={user.email} has role={user.role}, "
                f"which does not match --role {role} (expected one of {sorted(accepted)})."
            )
        return user

    def _get_or_create_service_user(self, role: str) -> User:
        mapped = ROLE_TO_USER_ROLE[role]
        email = f"attendance-api-{role}@{SERVICE_EMAIL_DOMAIN}"
        username = email
        user, created = User.objects.get_or_create(
            email=email,
            defaults={
                "username": username,
                "role": mapped,
                "full_name": f"Attendance API ({role})",
                "email_verified": True,
                "is_active": True,
            },
        )
        if not created and user.role != mapped:
            raise CommandError(
                f"Service user {email} exists with role={user.role}, "
                f"expected {mapped}."
            )
        # Always ensure token-only: no password login via Flutter form.
        user.username = username
        user.role = mapped
        user.email_verified = True
        user.is_active = True
        user.set_unusable_password()
        user.save()
        return user
