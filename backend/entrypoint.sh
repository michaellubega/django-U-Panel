#!/bin/sh
set -e

echo "Waiting for database..."
python <<'PY'
import os
import sys
import time

import dj_database_url
from django.db import connection
from django.db.utils import OperationalError

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "upanel.settings")

import django

django.setup()

url = os.environ.get("DATABASE_URL", "").strip()
if not url:
    sys.exit(0)

for attempt in range(1, 31):
    try:
        connection.ensure_connection()
        sys.exit(0)
    except OperationalError:
        if attempt == 30:
            raise
        print(f"  database not ready (attempt {attempt}/30), retrying...")
        time.sleep(2)
PY

python manage.py migrate --noinput
python manage.py collectstatic --noinput

exec "$@"
