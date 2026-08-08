from celery import shared_task


@shared_task(name="notices.push_notice_created")
def push_notice_created(notice_id: int) -> None:
    """Send OneSignal push when a notice is published (replaces FCM Cloud Function)."""
    from notices.models import Notice
    from upanel.services.onesignal import send_push, tag_for_list

    k_push_all_notices_tag = "all_notices"

    try:
        notice = Notice.objects.select_related("author").get(pk=notice_id)
    except Notice.DoesNotExist:
        return

    title = notice.title or "U-Panel notice"
    body = (notice.body or "")[:500]
    tags = None
    if notice.target_list_id:
        tags = {tag_for_list(notice.target_list_id): "true"}
    else:
        tags = {k_push_all_notices_tag: "true"}

    send_push(
        headings=title,
        contents=body or title,
        tags=tags,
        data={"noticeId": str(notice.id), "kind": notice.kind or ""},
    )


@shared_task(name="notices.publish_due_scheduled")
def publish_due_scheduled_notices() -> int:
    """Publish notices whose scheduled_for has passed (replaces scheduled Cloud Function)."""
    from django.utils import timezone

    from notices.models import Notice

    now = timezone.now()
    due = Notice.objects.filter(
        scheduled_for__lte=now,
        published_at__isnull=True,
    )
    count = 0
    for notice in due:
        notice.published_at = now
        notice.save(update_fields=["published_at"])
        push_notice_created.delay(notice.id)
        count += 1
    return count
