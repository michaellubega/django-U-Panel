import os
from pathlib import Path

import dj_database_url
from dotenv import load_dotenv

load_dotenv()

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.environ.get(
    "DJANGO_SECRET_KEY",
    "django-insecure-dev-only-change-in-production",
)

DEBUG = os.environ.get("DJANGO_DEBUG", "True").lower() in ("1", "true", "yes")

ALLOWED_HOSTS = [
    h.strip()
    for h in os.environ.get("DJANGO_ALLOWED_HOSTS", "localhost,127.0.0.1").split(",")
    if h.strip()
]

INSTALLED_APPS = [
    "upanel.apps.UpanelConfig",
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "django.contrib.humanize",
    "rest_framework",
    "rest_framework.authtoken",
    "corsheaders",
    "django_celery_beat",
    "accounts",
    "attendance",
    "notices",
    "campus",
    "documents",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    "corsheaders.middleware.CorsMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "upanel.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "upanel.wsgi.application"
ASGI_APPLICATION = "upanel.asgi.application"

# --- Database (PostgreSQL via DATABASE_URL, SQLite fallback for bare dev) ---
_use_sqlite = os.environ.get("DJANGO_USE_SQLITE", "").lower() in ("1", "true", "yes")
_database_url = os.environ.get("DATABASE_URL", "").strip()
if _database_url and not _use_sqlite:
    DATABASES = {
        "default": dj_database_url.parse(
            _database_url,
            conn_max_age=600,
            conn_health_checks=True,
        )
    }
else:
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.sqlite3",
            "NAME": BASE_DIR / "db.sqlite3",
        }
    }

AUTH_USER_MODEL = "accounts.User"

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LANGUAGE_CODE = "en-us"
TIME_ZONE = "UTC"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
STATICFILES_DIRS = [BASE_DIR / "upanel" / "static"]
STATIC_ROOT = BASE_DIR / "staticfiles"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

if not DEBUG:
    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
    _use_https = os.environ.get("PUBLIC_API_URL", "").startswith("https://")
    SESSION_COOKIE_SECURE = _use_https
    CSRF_COOKIE_SECURE = _use_https

CSRF_TRUSTED_ORIGINS = [
    o.strip()
    for o in os.environ.get("CSRF_TRUSTED_ORIGINS", "").split(",")
    if o.strip()
]

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework.authentication.TokenAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": [
        "rest_framework.permissions.IsAuthenticated",
    ],
}

CORS_ALLOWED_ORIGINS = [
    o.strip()
    for o in os.environ.get(
        "CORS_ALLOWED_ORIGINS",
        "http://localhost:3000,http://127.0.0.1:3000",
    ).split(",")
    if o.strip()
]
CORS_ALLOW_ALL_ORIGINS = DEBUG

# --- Email (Mailjet SMTP, generic SMTP, or console fallback) ---
_mailjet_api_key = os.environ.get("MAILJET_API_KEY", "").strip()
_mailjet_secret_key = os.environ.get("MAILJET_SECRET_KEY", "").strip()
_email_host = os.environ.get("EMAIL_HOST", "").strip()

if _mailjet_api_key and _mailjet_secret_key:
    EMAIL_BACKEND = "django.core.mail.backends.smtp.EmailBackend"
    EMAIL_HOST = "in-v3.mailjet.com"
    EMAIL_PORT = int(os.environ.get("EMAIL_PORT", "587"))
    EMAIL_HOST_USER = _mailjet_api_key
    EMAIL_HOST_PASSWORD = _mailjet_secret_key
    EMAIL_USE_TLS = os.environ.get("EMAIL_USE_TLS", "True").lower() in ("1", "true", "yes")
    EMAIL_USE_SSL = False
elif _email_host:
    EMAIL_BACKEND = "django.core.mail.backends.smtp.EmailBackend"
    EMAIL_HOST = _email_host
    EMAIL_PORT = int(os.environ.get("EMAIL_PORT", "587"))
    EMAIL_HOST_USER = os.environ.get("EMAIL_HOST_USER", "").strip()
    EMAIL_HOST_PASSWORD = os.environ.get("EMAIL_HOST_PASSWORD", "").strip()
    EMAIL_USE_TLS = os.environ.get("EMAIL_USE_TLS", "True").lower() in ("1", "true", "yes")
    EMAIL_USE_SSL = os.environ.get("EMAIL_USE_SSL", "False").lower() in ("1", "true", "yes")
else:
    EMAIL_BACKEND = "django.core.mail.backends.console.EmailBackend"

EMAIL_FROM_NAME = os.environ.get("EMAIL_FROM_NAME", "KIU-QA Department").strip()
EMAIL_FROM_ADDRESS = os.environ.get(
    "EMAIL_FROM_ADDRESS", "kiu-qa-department@orion13.us"
).strip().lower()

_default_from = os.environ.get("DEFAULT_FROM_EMAIL", "").strip()
if _default_from:
    DEFAULT_FROM_EMAIL = _default_from
elif EMAIL_FROM_ADDRESS:
    DEFAULT_FROM_EMAIL = f"{EMAIL_FROM_NAME} <{EMAIL_FROM_ADDRESS}>"
else:
    DEFAULT_FROM_EMAIL = "KIU-QA Department <noreply@localhost>"

# Base URL used in verification links (must be reachable from the user's mail client).
PUBLIC_API_URL = os.environ.get("PUBLIC_API_URL", "http://127.0.0.1:8000").strip()

# Deep link opened from the post-verification browser page (custom scheme or https app link).
APP_RETURN_URL = os.environ.get(
    "APP_RETURN_URL", "upanel://open/email-verified"
).strip()
APP_ANDROID_PACKAGE = os.environ.get("APP_ANDROID_PACKAGE", "com.u_panel").strip()

MAILJET_API_KEY = _mailjet_api_key
MAILJET_SECRET_KEY = _mailjet_secret_key

# Optional public URL for the logo in HTML emails (defaults to embedded app logo).
EMAIL_LOGO_URL = os.environ.get("EMAIL_LOGO_URL", "").strip()

# --- Redis cache (LocMem fallback when REDIS_URL is unset) ---
_redis_url = os.environ.get("REDIS_URL", "").strip()
if _redis_url:
    CACHES = {
        "default": {
            "BACKEND": "django_redis.cache.RedisCache",
            "LOCATION": _redis_url,
            "OPTIONS": {"CLIENT_CLASS": "django_redis.client.DefaultClient"},
        }
    }
else:
    CACHES = {
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
        }
    }

# --- Celery ---
CELERY_BROKER_URL = os.environ.get(
    "CELERY_BROKER_URL", "redis://localhost:6379/1"
)
CELERY_RESULT_BACKEND = os.environ.get(
    "CELERY_RESULT_BACKEND", "redis://localhost:6379/2"
)
CELERY_ACCEPT_CONTENT = ["json"]
CELERY_TASK_SERIALIZER = "json"
CELERY_RESULT_SERIALIZER = "json"
CELERY_TIMEZONE = TIME_ZONE
CELERY_BEAT_SCHEDULER = "django_celery_beat.schedulers:DatabaseScheduler"
CELERY_BEAT_SCHEDULE = {
    "publish-due-scheduled-notices": {
        "task": "notices.publish_due_scheduled",
        "schedule": 60.0,
    },
}

# --- OneSignal ---
ONESIGNAL_APP_ID = os.environ.get("ONESIGNAL_APP_ID", "").strip()
ONESIGNAL_REST_API_KEY = os.environ.get("ONESIGNAL_REST_API_KEY", "").strip()

# --- Sentry ---
_sentry_dsn = os.environ.get("SENTRY_DSN", "").strip()
if _sentry_dsn:
    import sentry_sdk
    from sentry_sdk.integrations.celery import CeleryIntegration
    from sentry_sdk.integrations.django import DjangoIntegration
    from sentry_sdk.integrations.redis import RedisIntegration

    sentry_sdk.init(
        dsn=_sentry_dsn,
        integrations=[
            DjangoIntegration(),
            CeleryIntegration(),
            RedisIntegration(),
        ],
        environment=os.environ.get("SENTRY_ENVIRONMENT", "development"),
        traces_sample_rate=0.1 if not DEBUG else 0.0,
        send_default_pii=False,
    )
