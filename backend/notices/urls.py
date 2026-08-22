from django.urls import path

from .views import NoticeListView

urlpatterns = [
    path("", NoticeListView.as_view(), name="notice-list"),
]
