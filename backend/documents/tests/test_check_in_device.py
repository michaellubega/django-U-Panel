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
