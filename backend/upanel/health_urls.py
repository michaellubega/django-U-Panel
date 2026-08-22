from django.http import JsonResponse
from django.urls import path

from upanel.services.onesignal import onesignal_configured


def health(_request):
    return JsonResponse(
        {
            "status": "ok",
            "service": "upanel-api",
            "push_delivery_configured": onesignal_configured(),
        }
    )


urlpatterns = [
    path("", health, name="health"),
]
