from django.urls import path

from .views import ConnectivityPingView

urlpatterns = [
    path("health/", ConnectivityPingView.as_view(), name="attendance-health"),
]
