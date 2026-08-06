from celery import shared_task


@shared_task(name="attendance.reconcile_check_in_attempt")
def reconcile_check_in_attempt(attempt_id: int) -> str:
    """
    Validate check-in evidence and write official attendance record.
    Replaces Firebase Cloud Function reconciliation (stub — extend with business rules).
    """
    from attendance.models import CheckInAttempt

    try:
        attempt = CheckInAttempt.objects.select_related("session").get(pk=attempt_id)
    except CheckInAttempt.DoesNotExist:
        return "missing"

    # TODO: GPS/geofence/session-code validation; write AttendanceRecord.
    return f"queued:{attempt.id}:{attempt.student_id}"


@shared_task(name="attendance.finalize_expired_sessions")
def finalize_expired_sessions() -> int:
    """Close sessions past end_time and finalize rolls (replaces Cloud Function scheduler)."""
    from django.utils import timezone

    from attendance.models import AttendanceSession

    now = timezone.now()
    expired = AttendanceSession.objects.filter(
        closed=False,
        end_time__lt=now,
    )
    return expired.update(closed=True)
