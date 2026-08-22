from celery import shared_task


@shared_task(name="notices.push_notice_document")
def push_notice_document(doc_id: str) -> bool:
    """Send OneSignal push for a notice ApiDocument."""
    from documents.models import ApiDocument
    from notices.push_from_document import mark_notice_push_sent, send_notice_push

    try:
        doc = ApiDocument.objects.get(collection="notices", doc_id=doc_id)
    except ApiDocument.DoesNotExist:
        return False

    data = doc.data or {}
    if send_notice_push(doc_id, data):
        mark_notice_push_sent(doc)
        return True
    return False


@shared_task(name="notices.push_notice_created")
def push_notice_created(notice_id: int) -> None:
    """Send OneSignal push when a legacy Django Notice is published."""
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
    """Push scheduled notices whose scheduledFor has passed (ApiDocument store)."""
    from django.utils import timezone

    from documents.models import ApiDocument
    from notices.push_from_document import (
        notice_data_is_live,
        notice_push_already_sent,
    )

    now = timezone.now()
    count = 0
    qs = ApiDocument.objects.filter(collection="notices")
    for doc in qs.iterator():
        data = doc.data or {}
        if not data.get("sendPush"):
            continue
        if notice_push_already_sent(data):
            continue
        if not data.get("scheduledFor"):
            continue
        if not notice_data_is_live(data, now=now):
            continue
        push_notice_document.delay(doc.doc_id)
        count += 1
    return count
