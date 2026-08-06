"""Create the default QA staff login used for QA screens (KIU-0001 / admin@kiu)."""

from django.core.management.base import BaseCommand

from accounts.models import User

QA_STAFF_NUMBER = "KIU-0001"
QA_LOGIN_EMAIL = "kiu0001@staff.upanel.local"
QA_DEFAULT_PASSWORD = "admin@kiu"
QA_FULL_NAME = "KIU QA Staff"


class Command(BaseCommand):
    help = (
        "Ensure QA demo account exists: staff ID KIU-0001, password admin@kiu "
        "(login email kiu0001@staff.upanel.local)."
    )

    def handle(self, *args, **options):
        user, created = User.objects.get_or_create(
            email=QA_LOGIN_EMAIL,
            defaults={
                "username": QA_LOGIN_EMAIL,
                "full_name": QA_FULL_NAME,
                "staff_number": QA_STAFF_NUMBER,
                "role": User.Role.QA_STAFF,
                "email_verified": True,
                "kiu_admin_onboarding_complete": True,
            },
        )
        if not created:
            user.username = QA_LOGIN_EMAIL
            user.full_name = QA_FULL_NAME
            user.staff_number = QA_STAFF_NUMBER
            user.role = User.Role.QA_STAFF
            user.email_verified = True
            user.kiu_admin_onboarding_complete = True
            user.is_staff = True
            user.is_active = True

        user.set_password(QA_DEFAULT_PASSWORD)
        user.save()

        action = "Created" if created else "Updated"
        self.stdout.write(
            self.style.SUCCESS(
                f"{action} QA demo user:\n"
                f"  Sign in with: {QA_STAFF_NUMBER}\n"
                f"  Password:     {QA_DEFAULT_PASSWORD}\n"
                f"  API email:    {QA_LOGIN_EMAIL}\n"
                f"  Role:         qa_staff"
            )
        )
