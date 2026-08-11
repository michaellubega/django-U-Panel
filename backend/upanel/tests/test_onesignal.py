from django.test import TestCase, override_settings
from unittest.mock import MagicMock, patch

from upanel.services.onesignal import (
    onesignal_authorization_header,
    onesignal_configured,
    send_push,
)


class OneSignalAuthTests(TestCase):
    def test_authorization_header_adds_key_prefix(self):
        self.assertEqual(
            onesignal_authorization_header("os_v2_app_example"),
            "Key os_v2_app_example",
        )

    def test_authorization_header_preserves_existing_prefix(self):
        self.assertEqual(
            onesignal_authorization_header("Key os_v2_app_example"),
            "Key os_v2_app_example",
        )
        self.assertEqual(
            onesignal_authorization_header("Basic legacy-key"),
            "Basic legacy-key",
        )


class OneSignalSendPushTests(TestCase):
    @override_settings(ONESIGNAL_APP_ID="", ONESIGNAL_REST_API_KEY="")
    def test_send_push_skips_when_unconfigured(self):
        self.assertFalse(send_push(headings="Hi", contents="Body", tags={"all_notices": "true"}))

    @override_settings(
        ONESIGNAL_APP_ID="882dcbec-c505-4c12-95c5-78da7e8ef25c",
        ONESIGNAL_REST_API_KEY="os_v2_app_test",
    )
    @patch("upanel.services.onesignal.requests.post")
    def test_send_push_uses_key_authorization(self, mock_post):
        mock_post.return_value = MagicMock(status_code=200, text="{}")
        self.assertTrue(
            send_push(
                headings="Notice",
                contents="Hello",
                tags={"all_notices": "true"},
            )
        )
        mock_post.assert_called_once()
        headers = mock_post.call_args.kwargs["headers"]
        self.assertEqual(headers["Authorization"], "Key os_v2_app_test")
        payload = mock_post.call_args.kwargs["json"]
        self.assertEqual(payload["target_channel"], "push")
        self.assertEqual(payload["app_id"], "882dcbec-c505-4c12-95c5-78da7e8ef25c")


class OneSignalConfiguredTests(TestCase):
    @override_settings(ONESIGNAL_APP_ID="app", ONESIGNAL_REST_API_KEY="")
    def test_requires_both_values(self):
        self.assertFalse(onesignal_configured())

    @override_settings(ONESIGNAL_APP_ID="app", ONESIGNAL_REST_API_KEY="key")
    def test_true_when_both_set(self):
        self.assertTrue(onesignal_configured())
