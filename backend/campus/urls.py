from django.urls import path

from .views import GeofenceView

urlpatterns = [
    path("geofence/", GeofenceView.as_view(), name="campus-geofence"),
]
