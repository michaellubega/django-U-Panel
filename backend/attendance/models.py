from django.conf import settings
from django.db import models


class AttendanceList(models.Model):
    title = models.CharField(max_length=255, blank=True)
    room = models.CharField(max_length=128, blank=True)
    who_taught = models.CharField(max_length=255, blank=True)
    date = models.DateField(null=True, blank=True)
    courses = models.JSONField(default=list, blank=True)
    year = models.CharField(max_length=32, blank=True)
    sem = models.CharField(max_length=32, blank=True)
    lecturer = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="attendance_lists",
    )
    creator = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="created_attendance_lists",
    )
    created_at = models.DateTimeField(auto_now_add=True)


class AttendanceSession(models.Model):
    list = models.ForeignKey(
        AttendanceList,
        on_delete=models.CASCADE,
        related_name="sessions",
    )
    join_code = models.CharField(max_length=16, db_index=True)
    start_time = models.DateTimeField(null=True, blank=True)
    end_time = models.DateTimeField(null=True, blank=True)
    closed = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)


class AttendanceRecord(models.Model):
    session = models.ForeignKey(
        AttendanceSession,
        on_delete=models.CASCADE,
        related_name="records",
    )
    student_id = models.CharField(max_length=64, db_index=True)
    status = models.CharField(max_length=32, default="pending")
    payload = models.JSONField(default=dict, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = ("session", "student_id")


class CheckInAttempt(models.Model):
    session = models.ForeignKey(
        AttendanceSession,
        on_delete=models.CASCADE,
        related_name="check_in_attempts",
    )
    student_id = models.CharField(max_length=64, db_index=True)
    payload = models.JSONField(default=dict, blank=True)
    awaiting_session = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
