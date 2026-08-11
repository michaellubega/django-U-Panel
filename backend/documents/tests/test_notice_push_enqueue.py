from unittest.mock import patch

from django.contrib.auth import get_user_model
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from documents.models import ApiDocument


class NoticeDocumentPushEnqueueTests(APITestCase):
    def setUp(self):
        user = get_user_model().objects.create_user(
            username="staff1",
            email="staff@kiu.ac.ug",
            password="pass12345",
        )
        self.token = Token.objects.create(user=user)
        self.client.credentials(HTTP_AUTHORIZATION=f"Token {self.token.key}")

    @patch("notices.tasks.push_notice_document.delay")
    def test_patch_notice_enqueues_push(self, mock_delay):
        doc = ApiDocument.objects.create(
            collection="notices",
            doc_id="notice-1",
            data={"title": "Hello", "sendPush": False},
        )
        response = self.client.patch(
            "/api/notices/notice-1/",
            {"sendPush": True, "title": "Hello"},
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        mock_delay.assert_called_once_with("notice-1")

    @patch("notices.tasks.push_notice_document.delay")
    def test_replace_notice_enqueues_push(self, mock_delay):
        response = self.client.post(
            "/api/notices/replace-1/",
            {
                "title": "Updated",
                "sendPush": True,
                "audience": "all",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201)
        mock_delay.assert_called_once_with("replace-1")
