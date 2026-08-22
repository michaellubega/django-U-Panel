from rest_framework import serializers

from .models import Notice


class NoticeSerializer(serializers.ModelSerializer):
    class Meta:
        model = Notice
        fields = (
            "id",
            "title",
            "body",
            "kind",
            "session_code",
            "target_list_id",
            "scheduled_for",
            "published_at",
            "created_at",
        )
