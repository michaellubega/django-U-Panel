from rest_framework import serializers

from .models import CampusGeofence


class CampusGeofenceSerializer(serializers.ModelSerializer):
    class Meta:
        model = CampusGeofence
        fields = ("latitude", "longitude", "radius_meters", "updated_at")
