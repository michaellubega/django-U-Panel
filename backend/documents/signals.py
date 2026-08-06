from django.db.models.signals import post_save
from django.dispatch import receiver

from accounts.models import User

from .services.user_sync import sync_user_profile


@receiver(post_save, sender=User)
def sync_user_documents(sender, instance: User, **kwargs):
    sync_user_profile(instance)
