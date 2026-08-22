from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import Notice
from .serializers import NoticeSerializer


class NoticeListView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        limit = min(int(request.query_params.get("limit", 40)), 100)
        qs = Notice.objects.order_by("-created_at")[:limit]
        return Response(NoticeSerializer(qs, many=True).data)
