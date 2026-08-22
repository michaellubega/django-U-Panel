from django.conf import settings
from django.db import models


class Notice(models.Model):
    title = models.CharField(max_length=255)
    body = models.TextField(blank=True)
    kind = models.CharField(max_length=64, blank=True)
    session_code = models.CharField(max_length=32, blank=True)
    target_list_id = models.CharField(max_length=64, blank=True)
    scheduled_for = models.DateTimeField(null=True, blank=True)
    published_at = models.DateTimeField(null=True, blank=True)
    author = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="notices",
    )
    created_at = models.DateTimeField(auto_now_add=True)
