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


@shared_task(
    name="documents.process_check_in_doc",
    bind=True,
    max_retries=5,
    default_retry_delay=4,
)
def process_check_in_doc(self, doc_id: str) -> str:
    """
    Process a single check-in attempt document asynchronously.
    Called after the HTTP response is sent so the POST returns quickly.
    """
    from documents.models import ApiDocument
    from documents.services.check_in import CHECK_IN_COLLECTION, maybe_process_check_in

    try:
        doc = ApiDocument.objects.get(collection=CHECK_IN_COLLECTION, doc_id=doc_id)
        maybe_process_check_in(doc)
        return f"processed:{doc_id}"
    except ApiDocument.DoesNotExist:
        return f"missing:{doc_id}"
    except Exception as exc:
        raise self.retry(exc=exc)


@shared_task(name="documents.sweep_awaiting_session_claims")
def sweep_awaiting_session_claims() -> int:
    """
    Server-side sweep: link awaitingSession claims to published sessions.

    Runs every 30 s via Celery Beat. Ensures check-ins submitted before the
    lecturer started their session get linked even when the student's app is
    in the background (Dart polling stopped).
    """
    from datetime import timedelta

    from django.utils import timezone

    from documents.models import ApiDocument
    from documents.services.check_in import CHECK_IN_COLLECTION, maybe_process_check_in

    cutoff = timezone.now() - timedelta(days=7)

    # Fetch up to 50 unresolved claims at a time; the task fires every 30 s so
    # a large backlog is drained across multiple runs.
    pending = list(
        ApiDocument.objects.filter(
            collection=CHECK_IN_COLLECTION,
            data__status="pending",
            created_at__gte=cutoff,
        )
        .order_by("created_at")[:50]
    )

    processed = 0
    for doc in pending:
        if not (doc.data or {}).get("awaitingSession"):
            continue
        maybe_process_check_in(doc)
        processed += 1

    return processed
