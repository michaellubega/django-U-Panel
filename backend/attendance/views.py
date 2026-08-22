from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView


class ConnectivityPingView(APIView):
    """Lightweight reachability check (replaces Firestore meta/connectivity ping)."""

    permission_classes = [AllowAny]

    def get(self, _request):
        return Response({"ok": True})
