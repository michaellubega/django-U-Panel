"""Custom admin views for U-Panel."""

from django.contrib.admin.views.decorators import staff_member_required
from django.http import JsonResponse
from django.shortcuts import render

from .server_monitor import get_health_status, get_server_health


@staff_member_required
def server_health_view(request):
    """Display server health and resource monitoring page."""
    health_data = get_health_status()
    context = {
        "title": "Server Health",
        "subtitle": "Resource Monitoring",
        **health_data,
    }
    return render(request, "admin/server_health.html", context)


@staff_member_required
def server_health_api(request):
    """API endpoint for real-time server health data (for auto-refresh)."""
    return JsonResponse(get_server_health())
