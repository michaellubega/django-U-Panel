from django.urls import path

from .views import DocumentRouterView

urlpatterns = [
    path("<path:resource_path>", DocumentRouterView.as_view()),
]
