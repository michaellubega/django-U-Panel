"""Create a sample attendance list in ApiDocument for QA / smoke testing."""

from datetime import date

from django.core.management.base import BaseCommand

from accounts.models import User
from documents.models import ApiDocument

QA_LOGIN_EMAIL = "kiu0001@staff.upanel.local"


class Command(BaseCommand):
    help = (
        "Ensure one demo attendance list exists in attendance/lists (Postgres). "
        "Run seed_qa_demo_user first if the QA account is missing."
    )

    def handle(self, *args, **options):
        try:
            user = User.objects.get(email=QA_LOGIN_EMAIL)
        except User.DoesNotExist:
            self.stderr.write(
                "QA user not found. Run: python manage.py seed_qa_demo_user"
            )
            return

        uid = str(user.pk)
        doc_id = "demo-attendance-list"
        payload = {
            "time": "09:00",
            "room": "Lab 1",
            "whoTaught": user.full_name or "KIU QA Staff",
            "date": date(2024, 1, 1).isoformat(),  # Monday
            "program": "day",
            "courses": ["Demo Course"],
            "year": "1",
            "sem": "1",
            "status": "active",
            "createdBy": uid,
            "lecturerUid": uid,
            "courseUnitName": "Demo Attendance List",
            "lecturerSignCode": "",
        }
        doc, created = ApiDocument.objects.update_or_create(
            collection="attendance/lists",
            doc_id=doc_id,
            defaults={"data": payload},
        )
        total = ApiDocument.objects.filter(collection="attendance/lists").count()
        action = "Created" if created else "Updated"
        self.stdout.write(
            self.style.SUCCESS(
                f"{action} demo list {doc.collection}/{doc.doc_id} "
                f"(lecturerUid={uid}). Total attendance/lists: {total}"
            )
        )
