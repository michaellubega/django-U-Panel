from django.test import TestCase

from notices.push_from_document import (
    notice_data_is_live,
    push_copy_for_notice,
    push_tags_for_notice,
)


class NoticePushFromDocumentTests(TestCase):
    def test_push_tags_class_list(self):
        tags = push_tags_for_notice(
            {
                "audience": "classList",
                "targetListId": "list/12",
            }
        )
        self.assertEqual(tags, {"list_list_12": "true"})

    def test_push_tags_student(self):
        tags = push_tags_for_notice(
            {
                "audience": "student",
                "targetStudentId": "stu-1",
            }
        )
        self.assertEqual(tags, {"stu_stu-1": "true"})

    def test_push_tags_lecturer_kind(self):
        tags = push_tags_for_notice(
            {
                "kind": "lecturerTakeAttendance",
                "targetLecturerUid": "uid-9",
            }
        )
        self.assertEqual(tags, {"lec_uid-9": "true"})

    def test_scheduled_notice_not_live(self):
        data = {
            "sendPush": True,
            "scheduledFor": "2099-01-01T12:00:00Z",
        }
        self.assertFalse(notice_data_is_live(data))

    def test_session_code_copy(self):
        title, body = push_copy_for_notice(
            {"kind": "sessionCode", "title": "Math 101", "body": ""}
        )
        self.assertEqual(title, "Math 101")
        self.assertIn("ready", body.lower())
