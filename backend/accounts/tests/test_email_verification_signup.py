from unittest.mock import patch

from django.test import TestCase, override_settings

from accounts.models import User
from accounts.services.email_verification import (
    EmailVerificationError,
    queue_verification_email,
)


@override_settings(
    CACHES={
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
        }
    }
)
class EmailVerificationSignupCooldownTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            username="staff@kiu.ac.ug",
            email="staff@kiu.ac.ug",
            password="secret12",
        )

    @patch("accounts.services.email_verification.send_verification_email_task")
    def test_signup_does_not_block_immediate_resend(self, task):
        queue_verification_email(self.user, is_signup=True)
        queue_verification_email(self.user, is_signup=False)
        self.assertEqual(task.delay.call_count, 2)

    @patch("accounts.services.email_verification.send_verification_email_task")
    def test_resend_still_rate_limited_after_manual_request(self, task):
        queue_verification_email(self.user, is_signup=False)
        with self.assertRaises(EmailVerificationError):
            queue_verification_email(self.user, is_signup=False)
        self.assertEqual(task.delay.call_count, 1)
