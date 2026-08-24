from django.test import TestCase

from documents.models import ApiDocument
from documents.services.check_in import maybe_process_check_in


class CheckInDeviceBlockTests(TestCase):
    def test_rejects_when_device_already_used_for_another_student(self) -> None:
        session_id = "sess-device-block"
        ApiDocument.objects.create(
            collection="attendance/sessions",
            doc_id=session_id,
            data={
                "listId": "list-1",
                "sessionCode": "JOIN01",
                "latitude": 0.3476,
                "longitude": 32.5825,
                "radiusMeters": 1500,
                "startTime": "2026-03-02T08:00:00+00:00",
                "endTime": "2026-03-02T10:00:00+00:00",
                "status": "active",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/records",
            doc_id=f"{session_id}_student-a",
            data={
                "sessionId": session_id,
                "studentId": "student-a",
                "deviceId": "phone-1",
                "present": True,
                "verified": True,
            },
        )
        attempt = ApiDocument.objects.create(
            collection="attendance/check-in-attempts",
            doc_id=f"{session_id}_student-b",
            data={
                "sessionId": session_id,
                "studentId": "student-b",
                "deviceId": "phone-1",
                "latitude": 0.3476,
                "longitude": 32.5825,
                "capturedAt": "2026-03-02T08:15:00+00:00",
                "status": "pending",
            },
        )

        maybe_process_check_in(attempt)
        attempt.refresh_from_db()

        self.assertEqual(attempt.data.get("status"), "rejected")
        self.assertIn(
            "device already used",
            (attempt.data.get("rejectionReason") or "").lower(),
        )

    def test_generic_android_id_does_not_block_other_students(self) -> None:
        session_id = "sess-generic-android-id"
        ApiDocument.objects.create(
            collection="attendance/sessions",
            doc_id=session_id,
            data={
                "listId": "list-1",
                "sessionCode": "JOIN02",
                "latitude": 0.3476,
                "longitude": 32.5825,
                "radiusMeters": 1500,
                "startTime": "2026-03-02T08:00:00+00:00",
                "endTime": "2026-03-02T10:00:00+00:00",
                "status": "active",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/records",
            doc_id=f"{session_id}_student-a",
            data={
                "sessionId": session_id,
                "studentId": "student-a",
                "deviceId": "9774d56d682e549c",
                "present": True,
                "verified": True,
            },
        )
        attempt = ApiDocument.objects.create(
            collection="attendance/check-in-attempts",
            doc_id=f"{session_id}_student-b",
            data={
                "sessionId": session_id,
                "studentId": "student-b",
                "deviceId": "9774d56d682e549c",
                "latitude": 0.3476,
                "longitude": 32.5825,
                "capturedAt": "2026-03-02T08:15:00+00:00",
                "status": "pending",
            },
        )

        maybe_process_check_in(attempt)
        attempt.refresh_from_db()

        self.assertEqual(attempt.data.get("status"), "accepted")
        self.assertTrue(
            ApiDocument.objects.filter(
                collection="attendance/records",
                doc_id=f"{session_id}_student-b",
            ).exists()
        )

    def test_unknown_device_id_does_not_block_other_students(self) -> None:
        session_id = "sess-unknown-device-id"
        ApiDocument.objects.create(
            collection="attendance/sessions",
            doc_id=session_id,
            data={
                "listId": "list-1",
                "sessionCode": "JOIN03",
                "latitude": 0.3476,
                "longitude": 32.5825,
                "radiusMeters": 1500,
                "startTime": "2026-03-02T08:00:00+00:00",
                "endTime": "2026-03-02T10:00:00+00:00",
                "status": "active",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/records",
            doc_id=f"{session_id}_student-a",
            data={
                "sessionId": session_id,
                "studentId": "student-a",
                "deviceId": "unknown",
                "present": True,
                "verified": True,
            },
        )
        attempt = ApiDocument.objects.create(
            collection="attendance/check-in-attempts",
            doc_id=f"{session_id}_student-b",
            data={
                "sessionId": session_id,
                "studentId": "student-b",
                "deviceId": "unknown",
                "latitude": 0.3476,
                "longitude": 32.5825,
                "capturedAt": "2026-03-02T08:15:00+00:00",
                "status": "pending",
            },
        )

        maybe_process_check_in(attempt)
        attempt.refresh_from_db()

        self.assertEqual(attempt.data.get("status"), "accepted")

    def test_rejected_device_block_keeps_list_id_from_session(self) -> None:
        session_id = "sess-stamp-list"
        ApiDocument.objects.create(
            collection="attendance/sessions",
            doc_id=session_id,
            data={
                "listId": "list-stamped",
                "sessionCode": "JOIN04",
                "latitude": 0.3476,
                "longitude": 32.5825,
                "radiusMeters": 1500,
                "startTime": "2026-03-02T08:00:00+00:00",
                "endTime": "2026-03-02T10:00:00+00:00",
                "status": "active",
            },
        )
        ApiDocument.objects.create(
            collection="attendance/records",
            doc_id=f"{session_id}_student-a",
            data={
                "sessionId": session_id,
                "studentId": "student-a",
                "deviceId": "phone-unique-1",
                "present": True,
                "verified": True,
            },
        )
        attempt = ApiDocument.objects.create(
            collection="attendance/check-in-attempts",
            doc_id=f"{session_id}_student-b",
            data={
                "sessionId": session_id,
                "studentId": "student-b",
                "deviceId": "phone-unique-1",
                "latitude": 0.3476,
                "longitude": 32.5825,
                "capturedAt": "2026-03-02T08:15:00+00:00",
                "status": "pending",
            },
        )

        maybe_process_check_in(attempt)
        attempt.refresh_from_db()

        self.assertEqual(attempt.data.get("status"), "rejected")
        self.assertEqual(attempt.data.get("listId"), "list-stamped")
        self.assertIn(
            "device already used",
            (attempt.data.get("rejectionReason") or "").lower(),
        )
