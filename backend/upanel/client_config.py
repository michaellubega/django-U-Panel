from django.conf import settings
from django.http import JsonResponse
from django.views.decorators.http import require_GET


@require_GET
def client_config(_request):
    """Public mobile/web client settings (no secrets)."""
    app_id = (settings.ONESIGNAL_APP_ID or "").strip()
    return JsonResponse(
        {
            "onesignal_app_id": app_id,
            "push_enabled": bool(app_id),
        }
    )
