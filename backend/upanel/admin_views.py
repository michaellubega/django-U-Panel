"""Custom admin views for U-Panel."""

from django.contrib.admin.views.decorators import staff_member_required
from django.http import JsonResponse
from django.shortcuts import render


def _server_monitor():
    from . import server_monitor

    return server_monitor


@staff_member_required
def server_health_view(request):
    """Display server health and resource monitoring page."""
    health_data = _server_monitor().get_health_status()
    context = {
        "title": "Server Health",
        "subtitle": "Resource Monitoring",
        **health_data,
    }
    return render(request, "admin/server_health.html", context)


@staff_member_required
def server_health_api(request):
    """API endpoint for real-time server health data (for auto-refresh)."""
    return JsonResponse(_server_monitor().get_server_health())
