"""Query helpers for schemaless JSON documents."""

from __future__ import annotations

from django.db.models import QuerySet

ORDERING_PARAM = "ordering"
LIMIT_PARAM = "limit"
RESERVED_QUERY_KEYS = frozenset({ORDERING_PARAM, LIMIT_PARAM})


def serialize_document(doc) -> dict:
    payload = dict(doc.data or {})
    payload["id"] = doc.doc_id
    return payload


def apply_document_filters(qs: QuerySet, params) -> QuerySet:
    for key, raw_value in params.items():
        if key in RESERVED_QUERY_KEYS:
            continue
        if raw_value is None or str(raw_value).strip() == "":
            continue
        lookup = _lookup_for_key(key)
        value = _coerce_value(raw_value, lookup)
        qs = qs.filter(**{f"data__{lookup}": value})

    ordering = (params.get(ORDERING_PARAM) or "").strip()
    if ordering:
        descending = ordering.startswith("-")
        field = ordering[1:] if descending else ordering
        order_expr = f"data__{field}"
        if descending:
            order_expr = f"-{order_expr}"
        qs = qs.order_by(order_expr, "doc_id")
    else:
        qs = qs.order_by("-updated_at", "doc_id")
    return qs


def apply_limit(qs: QuerySet, params, default: int = 100) -> QuerySet:
    try:
        limit = int(params.get(LIMIT_PARAM, default))
    except (TypeError, ValueError):
        limit = default
    limit = max(1, min(limit, 500))
    return qs[:limit]


def _lookup_for_key(key: str) -> str:
    if key.endswith("__in"):
        return key
    if key.endswith(("__gt", "__gte", "__lt", "__lte")):
        return key
    return key


def _coerce_value(raw, lookup: str):
    text = str(raw).strip()
    if lookup.endswith("__in"):
        return [part.strip() for part in text.split(",") if part.strip()]
    if lookup.endswith(("__gt", "__gte", "__lt", "__lte")):
        if text.lower() in ("true", "false"):
            return text.lower() == "true"
        try:
            if "." in text:
                return float(text)
            return int(text)
        except ValueError:
            return text
    if text.lower() == "true":
        return True
    if text.lower() == "false":
        return False
    # Equality filters must preserve string form — JSON docs store user ids and
    # registration numbers as strings (e.g. lecturerUid "12"). Coercing "12" to
    # int breaks PostgreSQL JSONField lookups against string values.
    return text
