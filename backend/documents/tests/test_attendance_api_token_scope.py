"""Attendance API token scoping + export endpoint tests."""

from io import StringIO

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.core.management.base import CommandError
from rest_framework.authtoken.models import Token
from rest_framework.test import APITestCase

from accounts.models import User
from documents.models import ApiDocument

UserModel = get_user_model()


class AttendanceApiTokenScopeTests(APITestCase):
    def setUp(self):
        self.student_a = UserModel.objects.create_user(
            username="stu-a",
            email="stu-a@example.com",
            password="pass12345",
            role=User.Role.STUDENT,
            registration_number="REG-A",
            full_name="Student A",
            email_verified=True,
        )
        self.student_b = UserModel.objects.create_user(
            username="stu-b",
            email="stu-b@example.com",
            password="pass12345",
            role=User.Role.STUDENT,
            registration_number="REG-B",
            full_name="Student B",
            email_verified=True,
        )
        self.lecturer_a = UserModel.objects.create_user(
            username="lec-a",
            email="lec-a@example.com",
            password="pass12345",
            role=User.Role.LECTURER,
            full_name="Lecturer A",
            email_verified=True,
        )
        self.lecturer_b = UserModel.objects.create_user(
            username="lec-b",
            email="lec-b@example.com",
            password="pass12345",
            role=User.Role.LECTURER,
            full_name="Lecturer B",
            email_verified=True,
        )
        self.admin = UserModel.objects.create_user(
            username="admin1",
            email="admin@example.com",
            password="pass12345",
            role=User.Role.ADMINISTRATOR,
            full_name="Admin One",
            email_verified=True,
        )

        self.token_student_a = Token.objects.create(user=self.student_a)
        self.token_student_b = Token.objects.create(user=self.student_b)
        self.token_lecturer_a = Token.objects.create(user=self.lecturer_a)
        self.token_lecturer_b = Token.objects.create(user=self.lecturer_b)
        self.token_admin = Token.objects.create(user=self.admin)

        ApiDocument.objects.create(
            collection="attendance/lists",
            doc_id="list-a",
            data={
                "lecturerUid": str(self.lecturer_a.pk),
                "whoTaught": "Lecturer A",
                "courseUnitName": "Math",
                "room": "R1",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/lists",
            doc_id="list-b",
            data={
                "lecturerUid": str(self.lecturer_b.pk),
                "whoTaught": "Lecturer B",
                "courseUnitName": "Physics",
                "room": "R2",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/sessions",
            doc_id="sess-a",
            data={
                "listId": "list-a",
                "sessionCode": "JOINAA",
                "status": "active",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/sessions",
            doc_id="sess-b",
            data={
                "listId": "list-b",
                "sessionCode": "JOINBB",
                "status": "active",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/records",
            doc_id="sess-a_REG-A",
            data={
                "sessionId": "sess-a",
                "studentId": "REG-A",
                "listId": "list-a",
                "course": "Math",
                "timestamp": "2026-03-01T10:00:00+00:00",
                "present": True,
                "verified": True,
            },
        )
        ApiDocument.objects.create(
            collection="attendance/records",
            doc_id="sess-b_REG-B",
            data={
                "sessionId": "sess-b",
                "studentId": "REG-B",
                "listId": "list-b",
                "course": "Physics",
                "timestamp": "2026-03-01T11:00:00+00:00",
                "present": True,
                "verified": True,
            },
        )
        ApiDocument.objects.create(
            collection="attendance/check-in-attempts",
            doc_id="sess-a_REG-A",
            data={
                "sessionId": "sess-a",
                "studentId": "REG-A",
                "listId": "list-a",
                "status": "accepted",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/check-in-attempts",
            doc_id="sess-b_REG-B",
            data={
                "sessionId": "sess-b",
                "studentId": "REG-B",
                "listId": "list-b",
                "status": "accepted",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/lists",
            doc_id="list-created-a",
            data={
                "createdBy": str(self.lecturer_a.pk),
                "whoTaught": "Lecturer A",
                "courseUnitName": "Chemistry",
                "room": "R3",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/sign-ins",
            doc_id="signin-a",
            data={
                "listId": "list-a",
                "studentId": "REG-A",
                "registrationNumber": "REG-A",
                "studentName": "Student A",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/sign-ins",
            doc_id="signin-b",
            data={
                "listId": "list-b",
                "studentId": "REG-B",
                "registrationNumber": "REG-B",
                "studentName": "Student B",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/students",
            doc_id="REG-A",
            data={
                "studentId": "REG-A",
                "name": "Student A",
                "registrationNumber": "REG-A",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/students",
            doc_id="REG-B",
            data={
                "studentId": "REG-B",
                "name": "Student B",
                "registrationNumber": "REG-B",
            },
        )

    def _auth(self, token: Token):
        self.client.credentials(HTTP_AUTHORIZATION=f"Token {token.key}")

    def test_unauthenticated_records_401(self):
        self.client.credentials()
        response = self.client.get("/api/attendance/records/")
        self.assertEqual(response.status_code, 401)

    def test_unauthenticated_export_401(self):
        self.client.credentials()
        response = self.client.get("/api/attendance/export/")
        self.assertEqual(response.status_code, 401)

    def test_student_cannot_see_another_students_record(self):
        self._auth(self.token_student_a)
        response = self.client.get("/api/attendance/records/")
        self.assertEqual(response.status_code, 200)
        ids = {row["id"] for row in response.json()}
        self.assertIn("sess-a_REG-A", ids)
        self.assertNotIn("sess-b_REG-B", ids)

        other = self.client.get("/api/attendance/records/sess-b_REG-B/")
        self.assertEqual(other.status_code, 404)

    def test_lecturer_cannot_see_another_lecturers_list(self):
        self._auth(self.token_lecturer_a)
        response = self.client.get("/api/attendance/lists/")
        self.assertEqual(response.status_code, 200)
        ids = {row["id"] for row in response.json()}
        self.assertEqual(ids, {"list-a", "list-created-a"})

        other = self.client.get("/api/attendance/lists/list-b/")
        self.assertEqual(other.status_code, 404)

    def test_lecturer_sees_created_by_lists_without_lecturer_uid(self):
        self._auth(self.token_lecturer_a)
        response = self.client.get(
            "/api/attendance/lists/",
            {"createdBy": str(self.lecturer_a.pk), "limit": "500"},
        )
        self.assertEqual(response.status_code, 200)
        ids = {row["id"] for row in response.json()}
        self.assertIn("list-created-a", ids)
        self.assertNotIn("list-b", ids)

    def test_lecturer_can_fetch_own_sign_ins_and_students(self):
        self._auth(self.token_lecturer_a)
        sign_ins = self.client.get(
            "/api/attendance/sign-ins/",
            {"listId": "list-a", "limit": "500"},
        )
        self.assertEqual(sign_ins.status_code, 200)
        self.assertEqual({row["id"] for row in sign_ins.json()}, {"signin-a"})

        other_sign_ins = self.client.get(
            "/api/attendance/sign-ins/",
            {"listId": "list-b"},
        )
        self.assertEqual(other_sign_ins.status_code, 200)
        self.assertEqual(other_sign_ins.json(), [])

        own_student = self.client.get("/api/attendance/students/REG-A/")
        self.assertEqual(own_student.status_code, 200)
        self.assertEqual(own_student.json()["id"], "REG-A")

        other_student = self.client.get("/api/attendance/students/REG-B/")
        self.assertEqual(other_student.status_code, 404)

    def test_lecturer_cannot_see_another_lecturers_sign_ins_unfiltered(self):
        self._auth(self.token_lecturer_a)
        response = self.client.get("/api/attendance/sign-ins/")
        self.assertEqual(response.status_code, 200)
        ids = {row["id"] for row in response.json()}
        self.assertEqual(ids, {"signin-a"})

    def test_admin_sees_both_lists_and_records(self):
        self._auth(self.token_admin)
        lists = self.client.get("/api/attendance/lists/")
        self.assertEqual(lists.status_code, 200)
        self.assertEqual(
            {row["id"] for row in lists.json()},
            {"list-a", "list-b", "list-created-a"},
        )

        records = self.client.get("/api/attendance/records/")
        self.assertEqual(records.status_code, 200)
        self.assertEqual(
            {row["id"] for row in records.json()},
            {"sess-a_REG-A", "sess-b_REG-B"},
        )

    def test_export_respects_student_scope(self):
        self._auth(self.token_student_a)
        response = self.client.get("/api/attendance/export/")
        self.assertEqual(response.status_code, 200)
        body = response.json()
        record_ids = {row["id"] for row in body["records"]}
        list_ids = {row["id"] for row in body["lists"]}
        session_ids = {row["id"] for row in body["sessions"]}
        self.assertEqual(record_ids, {"sess-a_REG-A"})
        self.assertEqual(list_ids, {"list-a"})
        self.assertEqual(session_ids, {"sess-a"})

    def test_export_respects_lecturer_scope(self):
        self._auth(self.token_lecturer_b)
        response = self.client.get("/api/attendance/export/")
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual({row["id"] for row in body["records"]}, {"sess-b_REG-B"})
        self.assertEqual({row["id"] for row in body["lists"]}, {"list-b"})
        self.assertEqual({row["id"] for row in body["sessions"]}, {"sess-b"})

    def test_export_admin_sees_all(self):
        self._auth(self.token_admin)
        response = self.client.get("/api/attendance/export/?limit=5000")
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(
            {row["id"] for row in body["records"]},
            {"sess-a_REG-A", "sess-b_REG-B"},
        )
        self.assertGreaterEqual(body["limit"], 1000)

    def test_rotate_invalidates_previous_token(self):
        old_key = self.token_admin.key
        out = StringIO()
        call_command(
            "create_attendance_api_token",
            "--role",
            "admin",
            "--user-id",
            str(self.admin.pk),
            "--rotate",
            stdout=out,
        )
        printed = out.getvalue()
        self.assertIn("token=", printed)
        new_key = None
        for line in printed.splitlines():
            if line.startswith("token="):
                new_key = line.split("=", 1)[1]
        self.assertIsNotNone(new_key)
        self.assertNotEqual(old_key, new_key)

        self.client.credentials(HTTP_AUTHORIZATION=f"Token {old_key}")
        denied = self.client.get("/api/attendance/records/")
        self.assertEqual(denied.status_code, 401)

        self.client.credentials(HTTP_AUTHORIZATION=f"Token {new_key}")
        ok = self.client.get("/api/attendance/records/")
        self.assertEqual(ok.status_code, 200)

    def test_create_service_user_admin_can_export_and_is_read_only(self):
        out = StringIO()
        call_command(
            "create_attendance_api_token",
            "--role",
            "admin",
            "--create-service-user",
            "--rotate",
            stdout=out,
        )
        token_key = None
        for line in out.getvalue().splitlines():
            if line.startswith("token="):
                token_key = line.split("=", 1)[1]
        self.assertTrue(token_key)

        service = UserModel.objects.get(email="attendance-api-admin@upanel.internal")
        self.assertFalse(service.has_usable_password())
        self.assertEqual(service.role, User.Role.ADMINISTRATOR)

        self.client.credentials(HTTP_AUTHORIZATION=f"Token {token_key}")
        export = self.client.get("/api/attendance/export/")
        self.assertEqual(export.status_code, 200)
        self.assertEqual(len(export.json()["records"]), 2)

        records = self.client.get("/api/attendance/records/")
        self.assertEqual(records.status_code, 200)
        self.assertEqual(len(records.json()), 2)

        write = self.client.post(
            "/api/attendance/records/",
            {"sessionId": "x", "studentId": "y"},
            format="json",
        )
        self.assertEqual(write.status_code, 403)

    def test_role_mismatch_exits_nonzero(self):
        with self.assertRaises(CommandError):
            call_command(
                "create_attendance_api_token",
                "--role",
                "admin",
                "--user-id",
                str(self.student_a.pk),
            )

    def test_student_service_token_only_own_rows(self):
        out = StringIO()
        call_command(
            "create_attendance_api_token",
            "--role",
            "student",
            "--user-id",
            str(self.student_b.pk),
            stdout=out,
        )
        token_key = None
        for line in out.getvalue().splitlines():
            if line.startswith("token="):
                token_key = line.split("=", 1)[1]
        self.assertTrue(token_key)

        self.client.credentials(HTTP_AUTHORIZATION=f"Token {token_key}")
        export = self.client.get("/api/attendance/export/")
        self.assertEqual(export.status_code, 200)
        self.assertEqual(
            {row["id"] for row in export.json()["records"]},
            {"sess-b_REG-B"},
        )

    def test_student_can_fetch_list_from_rejected_check_in_attempt(self):
        ApiDocument.objects.create(
            collection="attendance/check-in-attempts",
            doc_id="sess-b_REG-A",
            data={
                "sessionId": "sess-b",
                "studentId": "REG-A",
                "listId": "list-b",
                "status": "rejected",
                "rejectionReason": "device already used for another student",
            },
        )
        self._auth(self.token_student_a)
        response = self.client.get("/api/attendance/lists/list-b/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["id"], "list-b")
        self.assertEqual(response.json()["whoTaught"], "Lecturer B")

        other_record = self.client.get("/api/attendance/records/sess-b_REG-B/")
        self.assertEqual(other_record.status_code, 404)

    def test_student_can_fetch_list_from_attempt_session_without_list_id(self):
        ApiDocument.objects.create(
            collection="attendance/lists",
            doc_id="list-c",
            data={
                "lecturerUid": str(self.lecturer_a.pk),
                "whoTaught": "Lecturer A",
                "courseUnitName": "Biology",
                "room": "R4",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/sessions",
            doc_id="sess-c",
            data={
                "listId": "list-c",
                "sessionCode": "JOINCC",
                "status": "active",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/check-in-attempts",
            doc_id="sess-c_REG-A",
            data={
                "sessionId": "sess-c",
                "studentId": "REG-A",
                "status": "rejected",
                "rejectionReason": "device already used for another student",
            },
        )
        self._auth(self.token_student_a)
        response = self.client.get("/api/attendance/lists/list-c/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["id"], "list-c")

        self._auth(self.token_student_b)
        denied = self.client.get("/api/attendance/lists/list-c/")
        self.assertEqual(denied.status_code, 404)

    def test_non_attendance_collections_unchanged(self):
        ApiDocument.objects.create(
            collection="notices",
            doc_id="n1",
            data={"title": "Hello"},
        )
        self._auth(self.token_student_a)
        response = self.client.get("/api/notices/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.json()), 1)
