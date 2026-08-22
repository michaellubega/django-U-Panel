from celery import shared_task
import logging

logger = logging.getLogger(__name__)


@shared_task(name="accounts.send_verification_email", bind=True, max_retries=3)
def send_verification_email_task(self, user_id: int) -> None:
    """Send signup verification email in the background (SMTP must not block HTTP)."""
    from accounts.models import User
    from accounts.services.email_verification import (
        EmailVerificationError,
        send_verification_email,
    )
    from accounts.services.mailjet_email import MailDeliveryError

    try:
        user = User.objects.get(pk=user_id)
    except User.DoesNotExist:
        logger.warning("send_verification_email_task: user %s not found", user_id)
        return
    try:
        send_verification_email(user)
        logger.info("Verification email sent for user %s (%s)", user_id, user.email)
    except EmailVerificationError as exc:
        logger.warning(
            "Verification email skipped for user %s: %s",
            user_id,
            exc.message,
        )
        return
    except MailDeliveryError as exc:
        logger.error(
            "Verification email failed for user %s (%s): %s",
            user_id,
            user.email,
            exc.message,
        )
        raise self.retry(exc=exc, countdown=60 * (self.request.retries + 1))
    except Exception:
        logger.exception("Verification email failed for user %s", user_id)
        raise


@shared_task(name="accounts.send_password_reset_email", bind=True, max_retries=3)
def send_password_reset_email_task(self, user_id: int) -> None:
    """Send password-reset email in the background (SMTP must not block HTTP)."""
    from accounts.models import User
    from accounts.services.mailjet_email import MailDeliveryError
    from accounts.services.password_reset import send_password_reset_email

    try:
        user = User.objects.get(pk=user_id)
    except User.DoesNotExist:
        logger.warning("send_password_reset_email_task: user %s not found", user_id)
        return
    try:
        send_password_reset_email(user)
        logger.info("Password reset email sent for user %s (%s)", user_id, user.email)
    except MailDeliveryError as exc:
        logger.error(
            "Password reset email failed for user %s (%s): %s",
            user_id,
            user.email,
            exc.message,
        )
        raise self.retry(exc=exc, countdown=60 * (self.request.retries + 1))
    except Exception:
        logger.exception("Password reset email failed for user %s", user_id)
        raise
