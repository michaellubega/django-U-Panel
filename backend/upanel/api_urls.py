from django.urls import include, path

from accounts.urls import urlpatterns as accounts_urlpatterns
from documents.urls import urlpatterns as documents_urlpatterns
from upanel.client_config import client_config
from upanel.health_urls import health

urlpatterns = [
    # Must stay before the documents catch-all (`<path:resource_path>`).
    path("health/", health, name="api-health"),
    path("client-config/", client_config, name="api-client-config"),
    *accounts_urlpatterns,
    *documents_urlpatterns,
]
