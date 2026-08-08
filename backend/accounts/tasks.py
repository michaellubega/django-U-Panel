from celery import shared_task


@shared_task(name="accounts.send_verification_email")
def send_verification_email_task(user_id: int) -> None:
    """Send signup verification email in the background (SMTP must not block HTTP)."""
    from accounts.models import User
    from accounts.services.email_verification import send_verification_email

    try:
        user = User.objects.get(pk=user_id)
    except User.DoesNotExist:
        return
    send_verification_email(user)
