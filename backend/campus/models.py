from django.conf import settings
from django.db import models


class CampusGeofence(models.Model):
    latitude = models.FloatField()
    longitude = models.FloatField()
    radius_meters = models.FloatField(default=200)
    updated_at = models.DateTimeField(auto_now=True)


class AdminCampusPresence(models.Model):
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="campus_presence_events",
    )
    event_type = models.CharField(max_length=32)
    latitude = models.FloatField(null=True, blank=True)
    longitude = models.FloatField(null=True, blank=True)
    recorded_at = models.DateTimeField(auto_now_add=True)
