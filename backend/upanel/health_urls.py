from django.http import JsonResponse
from django.urls import path


def health(_request):
    return JsonResponse({"status": "ok", "service": "upanel-api"})


urlpatterns = [
    path("", health, name="health"),
]
