"""Send a test transactional email (Mailjet/SMTP/console) for server diagnostics."""

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError

from accounts.services.mailjet_email import MailDeliveryError, send_transactional_email


class Command(BaseCommand):
    help = "Send a test email to verify Mailjet/SMTP configuration on this server."

    def add_arguments(self, parser):
        parser.add_argument(
            "recipient",
            help="Email address to receive the test message.",
        )

    def handle(self, *args, **options):
        recipient = (options["recipient"] or "").strip().lower()
        if not recipient or "@" not in recipient:
            raise CommandError("Provide a valid recipient email address.")

        backend = getattr(settings, "EMAIL_BACKEND", "")
        has_mailjet = bool(
            getattr(settings, "MAILJET_API_KEY", "")
            and getattr(settings, "MAILJET_SECRET_KEY", "")
        )
        public_url = getattr(settings, "PUBLIC_API_URL", "")

        self.stdout.write(f"EMAIL_BACKEND: {backend}")
        self.stdout.write(f"Mailjet API keys configured: {has_mailjet}")
        self.stdout.write(f"PUBLIC_API_URL: {public_url}")
        self.stdout.write(f"From: {getattr(settings, 'DEFAULT_FROM_EMAIL', '')}")
        self.stdout.write(f"Sending test email to {recipient}…")

        try:
            send_transactional_email(
                to_email=recipient,
                to_name=recipient,
                subject="U-Panel test email",
                text_body=(
                    "This is a test message from your U-Panel server.\n\n"
                    f"PUBLIC_API_URL={public_url}\n"
                    "If you received this, outbound mail is working.\n"
                ),
            )
        except MailDeliveryError as exc:
            raise CommandError(f"Mail delivery failed: {exc.message}") from exc
        except Exception as exc:
            raise CommandError(f"Mail delivery failed: {exc}") from exc

        if not has_mailjet and "console" in backend.lower():
            self.stdout.write(
                self.style.WARNING(
                    "MAILJET_API_KEY / MAILJET_SECRET_KEY are empty — "
                    "email was printed to the worker/web console only, not delivered. "
                    "Add Mailjet keys to .env.production and restart web + worker."
                )
            )
        else:
            self.stdout.write(self.style.SUCCESS("Test email accepted by the mail provider."))
