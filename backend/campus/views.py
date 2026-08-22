from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import CampusGeofence
from .serializers import CampusGeofenceSerializer


class GeofenceView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, _request):
        row = CampusGeofence.objects.order_by("-updated_at").first()
        if row is None:
            return Response(None)
        return Response(CampusGeofenceSerializer(row).data)
