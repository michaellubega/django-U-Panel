from datetime import timedelta
from unittest.mock import patch

from django.core.cache import cache
from django.test import Client, TestCase, override_settings
from django.utils import timezone
from rest_framework.authtoken.models import Token

from accounts.models import PasswordResetToken, User
from accounts.services.password_reset import (
    PasswordResetError,
    queue_password_reset_email,
    reset_password_with_token,
    send_password_reset_email,
)


def _token_from_email_body(text_body: str) -> str:
    return text_body.split("token=")[1].split("\n")[0].strip()


@override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
        }
    },
    PUBLIC_API_URL="https://kiu.orion13.us",
)
class PasswordResetServiceTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(
            username="student@kiu.ac.ug",
            email="student@kiu.ac.ug",
            password="oldpass1",
        )

    @patch("accounts.tasks.send_password_reset_email_task")
    def test_queue_sends_task_for_existing_user(self, task):
        queue_password_reset_email(self.user.email)
        task.delay.assert_called_once_with(self.user.pk)

    @patch("accounts.tasks.send_password_reset_email_task")
    def test_queue_ignores_unknown_email(self, task):
        queue_password_reset_email("missing@kiu.ac.ug")
        task.delay.assert_not_called()

    @patch("accounts.tasks.send_password_reset_email_task")
    def test_queue_ignores_staff_synthetic_email(self, task):
        User.objects.create_user(
            username="KIU3454S",
            email="kiu3454s@staff.upanel.local",
            password="secret12",
        )
        queue_password_reset_email("kiu3454s@staff.upanel.local")
        task.delay.assert_not_called()

    @patch("accounts.tasks.send_password_reset_email_task")
    def test_rate_limit_blocks_rapid_resend(self, task):
        queue_password_reset_email(self.user.email)
        with self.assertRaises(PasswordResetError) as ctx:
            queue_password_reset_email(self.user.email)
        self.assertEqual(ctx.exception.code, "too-many-requests")
        self.assertEqual(task.delay.call_count, 1)

    @patch("accounts.services.password_reset.send_transactional_email")
    def test_send_creates_token_and_emails_link(self, send_email):
        send_password_reset_email(self.user)
        self.assertEqual(PasswordResetToken.objects.filter(user=self.user).count(), 1)
        send_email.assert_called_once()
        text_body = send_email.call_args.kwargs["text_body"]
        self.assertIn("/api/auth/password-reset/confirm/?token=", text_body)

    @patch("accounts.services.password_reset.send_transactional_email")
    def test_reset_with_token_updates_password(self, send_email):
        captured: dict[str, str] = {}

        def capture(**kwargs):
            captured["text_body"] = kwargs["text_body"]

        send_email.side_effect = capture
        send_password_reset_email(self.user)
        raw_token = _token_from_email_body(captured["text_body"])
        reset_password_with_token(raw_token, "newpass9")
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password("newpass9"))
        row = PasswordResetToken.objects.get(user=self.user)
        self.assertIsNotNone(row.used_at)

    @patch("accounts.services.password_reset.send_transactional_email")
    def test_reset_invalidates_auth_tokens(self, send_email):
        captured: dict[str, str] = {}

        def capture(**kwargs):
            captured["text_body"] = kwargs["text_body"]

        send_email.side_effect = capture
        Token.objects.create(user=self.user, key="deadbeef")
        send_password_reset_email(self.user)
        raw_token = _token_from_email_body(captured["text_body"])
        reset_password_with_token(raw_token, "newpass9")
        self.assertFalse(Token.objects.filter(user=self.user).exists())

    def test_reset_rejects_invalid_token(self):
        with self.assertRaises(PasswordResetError) as ctx:
            reset_password_with_token("not-a-real-token", "newpass9")
        self.assertEqual(ctx.exception.code, "invalid-token")

    @patch("accounts.services.password_reset.send_transactional_email")
    def test_reset_rejects_expired_token(self, send_email):
        captured: dict[str, str] = {}

        def capture(**kwargs):
            captured["text_body"] = kwargs["text_body"]

        send_email.side_effect = capture
        send_password_reset_email(self.user)
        raw_token = _token_from_email_body(captured["text_body"])
        row = PasswordResetToken.objects.get(user=self.user)
        row.expires_at = timezone.now() - timedelta(minutes=1)
        row.save(update_fields=["expires_at"])
        with self.assertRaises(PasswordResetError) as ctx:
            reset_password_with_token(raw_token, "newpass9")
        self.assertEqual(ctx.exception.code, "expired-token")


@override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
        }
    },
    PUBLIC_API_URL="https://kiu.orion13.us",
)
class PasswordResetApiTests(TestCase):
    def setUp(self):
        cache.clear()
        self.client = Client()
        self.user = User.objects.create_user(
            username="student@kiu.ac.ug",
            email="student@kiu.ac.ug",
            password="oldpass1",
        )

    @patch("accounts.tasks.send_password_reset_email_task")
    def test_password_reset_endpoint_queues_email(self, task):
        response = self.client.post(
            "/api/auth/password-reset/",
            data={"email": self.user.email},
            content_type="application/json",
        )
        self.assertEqual(response.status_code, 200)
        task.delay.assert_called_once_with(self.user.pk)

    def test_password_reset_requires_email(self):
        response = self.client.post(
            "/api/auth/password-reset/",
            data={},
            content_type="application/json",
        )
        self.assertEqual(response.status_code, 400)

    @patch("accounts.services.password_reset.send_transactional_email")
    def test_confirm_form_resets_password(self, send_email):
        captured: dict[str, str] = {}

        def capture(**kwargs):
            captured["text_body"] = kwargs["text_body"]

        send_email.side_effect = capture
        send_password_reset_email(self.user)
        token = _token_from_email_body(captured["text_body"])
        response = self.client.post(
            "/api/auth/password-reset/confirm/",
            data={
                "token": token,
                "new_password": "brandnew1",
                "confirm_password": "brandnew1",
            },
        )
        self.assertEqual(response.status_code, 200)
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password("brandnew1"))
