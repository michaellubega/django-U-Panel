from django.urls import include, path

from accounts.urls import urlpatterns as accounts_urlpatterns
from documents.urls import urlpatterns as documents_urlpatterns
from upanel.health_urls import health

urlpatterns = [
    # Must stay before the documents catch-all (`<path:resource_path>`).
    path("health/", health, name="api-health"),
    *accounts_urlpatterns,
    *documents_urlpatterns,
]
