from django.urls import path

from .views import (
    LoginView,
    LogoutView,
    MeView,
    PasswordChangeView,
    PasswordResetView,
    PushRegisterView,
    RegisterView,
    RequestVerificationView,
    VerifyEmailView,
)

urlpatterns = [
    path("auth/login/", LoginView.as_view(), name="auth-login"),
    path("auth/register/", RegisterView.as_view(), name="auth-register"),
    path("auth/logout/", LogoutView.as_view(), name="auth-logout"),
    path("auth/me/", MeView.as_view(), name="auth-me"),
    path("auth/password-reset/", PasswordResetView.as_view(), name="auth-password-reset"),
    path("auth/password-change/", PasswordChangeView.as_view(), name="auth-password-change"),
    path("auth/change-password/", PasswordChangeView.as_view(), name="auth-change-password"),
    path("auth/request-verification/", RequestVerificationView.as_view(), name="auth-request-verification"),
    path("auth/verify-email/", VerifyEmailView.as_view(), name="auth-verify-email"),
    path("push/register/", PushRegisterView.as_view(), name="push-register"),
]
