from django.contrib import admin
from django.http import JsonResponse
from django.urls import include, path

from .admin_views import server_health_api, server_health_view


def api_root(_request):
    return JsonResponse(
        {
            "service": "U-Panel API",
            "status": "ok",
            "endpoints": {
                "health": "/api/health/",
                "auth_login": "/api/auth/login/",
                "auth_me": "/api/auth/me/",
                "documents": "/api/{collection}/",
                "admin": "/admin/",
            },
        }
    )


urlpatterns = [
    path("", api_root, name="api-root"),
    path("admin/server-health/", server_health_view, name="server_health"),
    path("admin/server-health/api/", server_health_api, name="server_health_api"),
    path("admin/", admin.site.urls),
    path("api/", include("upanel.api_urls")),
]
