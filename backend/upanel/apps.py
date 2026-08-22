from django.apps import AppConfig


class UpanelConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "upanel"
    label = "upanel_core"

    def ready(self) -> None:
        from .admin_setup import configure_admin_site

        configure_admin_site()
