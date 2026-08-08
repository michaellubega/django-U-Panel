from django.db.models.signals import post_save, pre_delete
from django.dispatch import receiver

from accounts.models import User

from ..models import ApiDocument
from .services.user_sync import (
    ADMINS,
    LECTURERS,
    STAFF_NUMBERS,
    STUDENT_REGS,
    USERS,
    sync_user_profile,
)


@receiver(post_save, sender=User)
def sync_user_documents(sender, instance: User, **kwargs):
    sync_user_profile(instance)


@receiver(pre_delete, sender=User)
def delete_user_documents(sender, instance: User, **kwargs):
    uid = str(instance.pk)
    ApiDocument.objects.filter(collection=USERS, doc_id=uid).delete()
    ApiDocument.objects.filter(collection=ADMINS, doc_id=uid).delete()
    ApiDocument.objects.filter(collection=LECTURERS, doc_id=uid).delete()
    reg = (instance.registration_number or "").strip().upper()
    if reg:
        ApiDocument.objects.filter(collection=STUDENT_REGS, doc_id=reg).delete()
    staff = (instance.staff_number or "").strip().upper()
    if staff:
        ApiDocument.objects.filter(collection=STAFF_NUMBERS, doc_id=staff).delete()
