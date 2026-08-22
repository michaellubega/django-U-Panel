import logging

from django.conf import settings
from django.contrib.auth import authenticate
from django.shortcuts import render
from rest_framework import status
from rest_framework.authtoken.models import Token
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import PushDevice, User
from .serializers import PushDeviceSerializer, RegisterSerializer, UserSerializer
from .services.email_verification import (
    EmailVerificationError,
    queue_verification_email,
    verify_email_token,
)
from .services.password_reset import (
    PasswordResetError,
    queue_password_reset_email,
    reset_password_with_token,
)
from .services.login_identifier import resolve_user_for_login

logger = logging.getLogger(__name__)


class MeView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        return Response(UserSerializer(request.user).data)

    def patch(self, request):
        user = request.user
        full_name = request.data.get("full_name")
        if full_name is not None:
            user.full_name = str(full_name).strip()
            user.save(update_fields=["full_name"])
        return Response(UserSerializer(user).data)

    def delete(self, request):
        user = request.user
        Token.objects.filter(user=user).delete()
        user.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


class LoginView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        login_id = (request.data.get("email") or request.data.get("login") or "").strip()
        password = request.data.get("password") or ""
        if not login_id or not password:
            return Response(
                {"detail": "Email and password are required."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        user = resolve_user_for_login(login_id)
        if user is not None:
            user = authenticate(username=user.username, password=password)
        if user is None and "@" in login_id:
            email = login_id.lower()
            user = authenticate(username=email, password=password)
            if user is None:
                try:
                    user = User.objects.get(email=email)
                    user = authenticate(username=user.username, password=password)
                except User.DoesNotExist:
                    user = None
        if user is None:
            return Response(
                {"detail": "Wrong email or password."},
                status=status.HTTP_401_UNAUTHORIZED,
            )
        token, _ = Token.objects.get_or_create(user=user)
        return Response({"token": token.key, "user": UserSerializer(user).data})


class RegisterView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        serializer = RegisterSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        user = serializer.save()
        token, _ = Token.objects.get_or_create(user=user)
        if not user.email_verified:
            try:
                queue_verification_email(user, is_signup=True)
            except EmailVerificationError as exc:
                logger.warning(
                    "Register: could not queue verification for %s: %s",
                    user.email,
                    exc.message,
                )
            except Exception:
                logger.exception(
                    "Register: failed to queue verification for %s", user.email
                )
        return Response(
            {"token": token.key, "user": UserSerializer(user).data},
            status=status.HTTP_201_CREATED,
        )


class PasswordResetView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        email = (request.data.get("email") or "").strip().lower()
        if not email:
            return Response(
                {"detail": "Email is required."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        try:
            queue_password_reset_email(email)
        except PasswordResetError as exc:
            if exc.code == "too-many-requests":
                return Response(
                    {"detail": exc.message},
                    status=status.HTTP_429_TOO_MANY_REQUESTS,
                )
            return Response(
                {"detail": exc.message},
                status=status.HTTP_400_BAD_REQUEST,
            )
        except Exception:
            logger.exception("Failed to queue password reset for %s", email)
            return Response(
                {"detail": "Could not send reset email. Try again later."},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        return Response({"detail": "If that account exists, a reset link was sent."})


class PasswordResetConfirmView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        raw_token = request.query_params.get("token", "")
        return render(
            request,
            "accounts/password_reset_confirm.html",
            {
                "success": False,
                "title": "Choose a new password",
                "message": "Enter a new password for your U-Panel account.",
                "show_form": True,
                "token": raw_token,
                "form_error": None,
            },
        )

    def post(self, request):
        raw_token = (
            request.data.get("token")
            or request.POST.get("token")
            or request.query_params.get("token")
            or ""
        )
        new_password = (
            request.data.get("new_password")
            or request.POST.get("new_password")
            or ""
        )
        confirm = (
            request.data.get("confirm_password")
            or request.POST.get("confirm_password")
            or ""
        )
        if new_password != confirm:
            return render(
                request,
                "accounts/password_reset_confirm.html",
                {
                    "success": False,
                    "title": "Choose a new password",
                    "message": "Enter a new password for your U-Panel account.",
                    "show_form": True,
                    "token": raw_token,
                    "form_error": "Passwords do not match.",
                },
                status=400,
            )
        try:
            reset_password_with_token(raw_token, new_password)
        except PasswordResetError as exc:
            return render(
                request,
                "accounts/password_reset_confirm.html",
                {
                    "success": False,
                    "title": "Reset failed",
                    "message": exc.message,
                    "show_form": exc.code in {"weak-password"},
                    "token": raw_token,
                    "form_error": exc.message if exc.code == "weak-password" else None,
                },
                status=400,
            )
        return render(
            request,
            "accounts/password_reset_confirm.html",
            {
                "success": True,
                "title": "Password updated",
                "message": "Your password has been changed. You can now sign in to U-Panel.",
                "show_form": False,
                "return_url": settings.APP_RETURN_URL,
            },
        )


class RequestVerificationView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        user = request.user
        if user.email_verified:
            return Response({"detail": "Email is already verified."})
        try:
            queue_verification_email(user)
        except EmailVerificationError as exc:
            return Response({"detail": exc.message}, status=status.HTTP_429_TOO_MANY_REQUESTS)
        except Exception:
            logger.exception("Failed to queue verification email for %s", user.email)
            return Response(
                {"detail": "Could not queue verification email. Try again later."},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        return Response({"detail": "Verification email sent."})


class VerifyEmailView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        raw_token = request.query_params.get("token", "")
        try:
            verify_email_token(raw_token)
        except EmailVerificationError as exc:
            return render(
                request,
                "accounts/email_verification_result.html",
                {
                    "success": False,
                    "title": "Verification failed",
                    "message": exc.message,
                },
                status=400,
            )
        return render(
            request,
            "accounts/email_verification_result.html",
            {
                "success": True,
                "title": "Email verified",
                "message": "Your email address has been verified successfully.",
                "return_url": settings.APP_RETURN_URL,
                "android_package": settings.APP_ANDROID_PACKAGE,
            },
        )


class PasswordChangeView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        current = request.data.get("current_password") or ""
        new_password = request.data.get("new_password") or ""
        if not request.user.check_password(current):
            return Response(
                {"detail": "Current password is incorrect."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if len(new_password) < 6:
            return Response(
                {"detail": "Password must be at least 6 characters."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        request.user.set_password(new_password)
        request.user.save(update_fields=["password"])
        Token.objects.filter(user=request.user).delete()
        token, _ = Token.objects.get_or_create(user=request.user)
        return Response({"token": token.key})


class LogoutView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        Token.objects.filter(user=request.user).delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


class PushRegisterView(APIView):
    """Register OneSignal player id for the signed-in user (replaces FCM token upload)."""

    permission_classes = [IsAuthenticated]

    def post(self, request):
        player_id = (request.data.get("player_id") or "").strip()
        if not player_id:
            return Response(
                {"detail": "player_id is required."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        platform = (request.data.get("platform") or PushDevice.Platform.UNKNOWN).strip()
        if platform not in PushDevice.Platform.values:
            platform = PushDevice.Platform.UNKNOWN
        tags = request.data.get("tags")
        if not isinstance(tags, dict):
            tags = {}

        device, _ = PushDevice.objects.update_or_create(
            player_id=player_id,
            defaults={
                "user": request.user,
                "platform": platform,
                "tags": tags,
            },
        )
        return Response(PushDeviceSerializer(device).data, status=status.HTTP_200_OK)

    def delete(self, request):
        player_id = (request.data.get("player_id") or request.query_params.get("player_id") or "").strip()
        if player_id:
            PushDevice.objects.filter(user=request.user, player_id=player_id).delete()
        else:
            PushDevice.objects.filter(user=request.user).delete()
        return Response(status=status.HTTP_204_NO_CONTENT)
