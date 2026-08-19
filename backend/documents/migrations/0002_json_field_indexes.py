"""
Add partial B-Tree indexes on frequently queried JSON paths inside
ApiDocument.data. These replace full-collection scans for the most
common attendance queries (session code lookup, status checks,
awaitingSession claims).

Requires PostgreSQL 12+ with the btree_gin extension (included by
default in Postgres distributions). The GIN index covers arbitrary
JSONField lookups; the functional B-Tree indexes accelerate the
exact-match cases that dominate attendance traffic.

Note: indexes are created without CONCURRENTLY so this migration can
run inside Django's standard transaction wrapper. The table is small
enough at startup that the brief lock is acceptable.
"""
from django.db import migrations
try:
    from django.contrib.postgres.indexes import GinIndex
    from django.contrib.postgres.operations import CreateExtension
    _HAS_PG_CONTRIB = True
except ImportError:  # non-PostgreSQL test runners
    _HAS_PG_CONTRIB = False


_gin_index = (
    migrations.AddIndex(
        model_name="apidocument",
        index=GinIndex(fields=["data"], name="doc_data_gin"),
    )
    if _HAS_PG_CONTRIB
    else migrations.RunSQL("SELECT 1;", reverse_sql="SELECT 1;")
)


class Migration(migrations.Migration):

    dependencies = [
        ("documents", "0001_initial"),
    ]

    operations = [
        # Enable btree_gin if available (needed for GIN on non-array types).
        *(
            [CreateExtension("btree_gin")]
            if _HAS_PG_CONTRIB
            else []
        ),
        # Full GIN index on the data column — allows arbitrary JSONField lookups.
        _gin_index,
        # Partial index: active sessions only (most common read path for check-in).
        migrations.RunSQL(
            """
            CREATE INDEX IF NOT EXISTS doc_data_active_sessions_idx
            ON documents_apidocument (
                (data ->> 'sessionCode'),
                (data ->> 'status')
            )
            WHERE collection = 'attendance/sessions';
            """,
            reverse_sql="DROP INDEX IF EXISTS doc_data_active_sessions_idx;",
        ),
        # Partial index: pending check-in attempts awaiting session link.
        migrations.RunSQL(
            """
            CREATE INDEX IF NOT EXISTS doc_data_awaiting_claims_idx
            ON documents_apidocument (
                (data ->> 'sessionCodeRaw'),
                (data ->> 'status')
            )
            WHERE collection = 'attendance/check-in-attempts'
              AND (data ->> 'awaitingSession') = 'true';
            """,
            reverse_sql="DROP INDEX IF EXISTS doc_data_awaiting_claims_idx;",
        ),
        # Partial index: attendance records by session (roll display).
        migrations.RunSQL(
            """
            CREATE INDEX IF NOT EXISTS doc_data_records_session_idx
            ON documents_apidocument (
                (data ->> 'sessionId')
            )
            WHERE collection = 'attendance/records';
            """,
            reverse_sql="DROP INDEX IF EXISTS doc_data_records_session_idx;",
        ),
    ]
