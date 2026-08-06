from django.contrib import admin
from django.http import JsonResponse
from django.urls import include, path


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
    path("admin/", admin.site.urls),
    path("api/", include("upanel.api_urls")),
]
