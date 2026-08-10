import uuid

from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .filters import apply_document_filters, apply_limit, serialize_document
from .models import ApiDocument
from .routing import split_resource_path
from .services.check_in import maybe_process_check_in


class DocumentRouterView(APIView):
    """Routes `/api/{collection}/` and `/api/{collection}/{doc_id}/` requests."""

    permission_classes = [IsAuthenticated]

    def get(self, request, resource_path: str = ""):
        collection, doc_id = split_resource_path(resource_path)
        if not collection:
            return Response({"detail": "Not found."}, status=status.HTTP_404_NOT_FOUND)
        if doc_id is None:
            return _list_documents(request, collection)
        return _get_document(collection, doc_id)

    def post(self, request, resource_path: str = ""):
        collection, doc_id = split_resource_path(resource_path)
        if not collection:
            return Response({"detail": "Not found."}, status=status.HTTP_404_NOT_FOUND)
        if doc_id is None:
            return _create_document(request, collection)
        return _replace_document(request, collection, doc_id)

    def patch(self, request, resource_path: str = ""):
        collection, doc_id = split_resource_path(resource_path)
        if not collection or doc_id is None:
            return Response({"detail": "Not found."}, status=status.HTTP_404_NOT_FOUND)
        return _patch_document(request, collection, doc_id)

    def delete(self, request, resource_path: str = ""):
        collection, doc_id = split_resource_path(resource_path)
        if not collection or doc_id is None:
            return Response({"detail": "Not found."}, status=status.HTTP_404_NOT_FOUND)
        return _delete_document(collection, doc_id)


def _list_documents(request, collection: str) -> Response:
    qs = ApiDocument.objects.filter(collection=collection)
    qs = apply_document_filters(qs, request.query_params)
    docs = apply_limit(qs, request.query_params)
    return Response([serialize_document(doc) for doc in docs])


def _get_document(collection: str, doc_id: str) -> Response:
    doc = _get_doc_or_none(collection, doc_id)
    if doc is None:
        return Response({"detail": "Not found."}, status=status.HTTP_404_NOT_FOUND)
    return Response(serialize_document(doc))


def _create_document(request, collection: str) -> Response:
    payload = _payload_dict(request.data)
    doc_id = (payload.pop("id", None) or "").strip() or str(uuid.uuid4())
    doc, created = ApiDocument.objects.update_or_create(
        collection=collection,
        doc_id=doc_id,
        defaults={"data": payload},
    )
    maybe_process_check_in(doc)
    if collection == "notices":
        from notices.push_from_document import maybe_enqueue_notice_push

        maybe_enqueue_notice_push(doc)
    code = status.HTTP_201_CREATED if created else status.HTTP_200_OK
    return Response(serialize_document(doc), status=code)


def _replace_document(request, collection: str, doc_id: str) -> Response:
    payload = _payload_dict(request.data)
    payload.pop("id", None)
    doc, created = ApiDocument.objects.update_or_create(
        collection=collection,
        doc_id=doc_id,
        defaults={"data": payload},
    )
    maybe_process_check_in(doc)
    code = status.HTTP_201_CREATED if created else status.HTTP_200_OK
    return Response(serialize_document(doc), status=code)


def _patch_document(request, collection: str, doc_id: str) -> Response:
    doc = _get_doc_or_none(collection, doc_id)
    if doc is None:
        doc = ApiDocument(collection=collection, doc_id=doc_id, data={})
    merged = dict(doc.data or {})
    patch = _payload_dict(request.data)
    patch.pop("id", None)
    for key, value in patch.items():
        if value is None:
            merged.pop(key, None)
        else:
            merged[key] = value
    doc.data = merged
    doc.save()
    maybe_process_check_in(doc)
    return Response(serialize_document(doc))


def _delete_document(collection: str, doc_id: str) -> Response:
    deleted, _ = ApiDocument.objects.filter(
        collection=collection,
        doc_id=doc_id,
    ).delete()
    if not deleted:
        return Response({"detail": "Not found."}, status=status.HTTP_404_NOT_FOUND)
    return Response(status=status.HTTP_204_NO_CONTENT)


def _get_doc_or_none(collection: str, doc_id: str) -> ApiDocument | None:
    try:
        return ApiDocument.objects.get(collection=collection, doc_id=doc_id)
    except ApiDocument.DoesNotExist:
        return None


def _payload_dict(data) -> dict:
    if isinstance(data, dict):
        return dict(data)
    return {}
