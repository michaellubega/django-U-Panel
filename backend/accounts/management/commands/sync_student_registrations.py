"""Backfill User.registration_number from student-registrations documents."""

from django.core.management.base import BaseCommand

from accounts.models import StudentRegistration, User
from documents.models import ApiDocument
from documents.services.user_sync import STUDENT_REGS, sync_user_profile


class Command(BaseCommand):
    help = "Copy registration numbers from accounts/student-registrations docs onto User rows."

    def handle(self, *args, **options):
        updated_users = 0
        updated_claims = 0
        for doc in ApiDocument.objects.filter(collection=STUDENT_REGS):
            data = doc.data or {}
            reg = (doc.doc_id or data.get("registrationNumber") or "").strip().upper()
            uid = (data.get("uid") or "").strip()
            if not reg or not uid:
                continue
            try:
                user = User.objects.get(pk=int(uid))
            except (User.DoesNotExist, ValueError, TypeError):
                self.stdout.write(
                    self.style.WARNING(f"Skip {reg}: user id {uid!r} not found")
                )
                continue
            changed = False
            if user.registration_number != reg:
                user.registration_number = reg
                user.save(update_fields=["registration_number"])
                updated_users += 1
                changed = True
            verified = bool(data.get("emailVerifiedAtLink"))
            claim, created = StudentRegistration.objects.update_or_create(
                registration_number=reg,
                defaults={
                    "user": user,
                    "email_verified_at_link": verified,
                },
            )
            if created or changed:
                updated_claims += 1
            sync_user_profile(user)

        self.stdout.write(
            self.style.SUCCESS(
                f"Updated {updated_users} user(s) and {updated_claims} registration claim(s)."
            )
        )
