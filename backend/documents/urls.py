from django.urls import path

from .export import AttendanceExportView
from .views import DocumentRouterView

urlpatterns = [
    # Must stay before the documents catch-all (`<path:resource_path>`).
    path("attendance/export/", AttendanceExportView.as_view(), name="attendance-export"),
    path("<path:resource_path>", DocumentRouterView.as_view()),
]
