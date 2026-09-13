"""Seed read-only leadership (oversight) demo accounts for Contabo test."""

from django.core.management.base import BaseCommand

from accounts.models import User

# staff ID / email local-part / role / display name
OVERSIGHT_DEMO = (
    ("KIU-VC01", "vc", User.Role.VC, "Demo Vice-Chancellor"),
    ("KIU-DVC1", "dvc", User.Role.DVC, "Demo Deputy VC"),
    ("KIU-DQA1", "dqa", User.Role.DQA, "Demo Director of QA"),
    ("KIU-DEAN", "dean", User.Role.DEAN, "Demo Dean"),
    ("KIU-HOD1", "hod", User.Role.HOD, "Demo Head of Department"),
)

DEFAULT_PASSWORD = "qaat@kiu"


class Command(BaseCommand):
    help = (
        "Ensure VC/DVC/DQA/Dean/HOD demo accounts exist for QAAT oversight UI. "
        f"Default password: {DEFAULT_PASSWORD}"
    )

    def add_arguments(self, parser):
        parser.add_argument(
            "--password",
            default=DEFAULT_PASSWORD,
            help=f"Password for all seeded oversight users (default {DEFAULT_PASSWORD})",
        )

    def handle(self, *args, **options):
        password = options["password"]
        lines = []
        for staff_id, local, role, full_name in OVERSIGHT_DEMO:
            email = f"{local}@oversight.upanel.local"
            user, created = User.objects.get_or_create(
                email=email,
                defaults={
                    "username": email,
                    "full_name": full_name,
                    "staff_number": staff_id,
                    "role": role,
                    "email_verified": True,
                    "kiu_admin_onboarding_complete": True,
                    "is_staff": False,
                    "is_active": True,
                },
            )
            user.username = email
            user.full_name = full_name
            user.staff_number = staff_id
            user.role = role
            user.email_verified = True
            user.kiu_admin_onboarding_complete = True
            user.is_staff = False
            user.is_active = True
            user.set_password(password)
            user.save()
            action = "Created" if created else "Updated"
            lines.append(
                f"  {action}: sign-in {staff_id}  role={role}  email={email}"
            )

        self.stdout.write(
            self.style.SUCCESS(
                "Oversight demo users ready (read-only QAAT home):\n"
                + "\n".join(lines)
                + f"\n  Password: {password}\n"
                "  Expect dark KIU-QAAT banner + slate KPIs on Dashboard "
                "(nav: Dashboard · Reports · Notices · Settings)."
            )
        )
