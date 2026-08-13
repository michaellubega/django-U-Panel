from unittest.mock import patch

from django.contrib.auth import get_user_model
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from documents.models import ApiDocument


class MissedSessionNoticeEnqueueTests(APITestCase):
    def setUp(self):
        user = get_user_model().objects.create_user(
            username="staff1",
            email="staff@kiu.ac.ug",
            password="pass12345",
        )
        self.token = Token.objects.create(user=user)
        self.client.credentials(HTTP_AUTHORIZATION=f"Token {self.token.key}")

    @patch("notices.tasks.push_notice_document.delay")
    def test_absent_attendance_record_creates_missed_session_notice(self, mock_delay):
        ApiDocument.objects.create(
            collection="attendance/sessions",
            doc_id="sess-1",
            data={"listId": "list-1", "title": "Math 101"},
        )
        ApiDocument.objects.create(
            collection="attendance/lists",
            doc_id="list-1",
            data={"title": "Math 101"},
        )

        response = self.client.post(
            "/api/attendance/records/sess-1_stu-1/",
            {
                "sessionId": "sess-1",
                "studentId": "stu-1",
                "listId": "list-1",
                "present": False,
                "course": "Math",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201)

        notice = ApiDocument.objects.get(
            collection="notices",
            doc_id="missed_sess-1_stu-1",
        )
        self.assertEqual(notice.data.get("kind"), "missedSession")
        self.assertEqual(notice.data.get("audience"), "student")
        self.assertTrue(notice.data.get("sendPush"))
        mock_delay.assert_called_once_with("missed_sess-1_stu-1")
