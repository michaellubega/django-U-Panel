from django.test import TestCase

from documents.filters import _coerce_value
from documents.models import ApiDocument


class DocumentFilterCoercionTests(TestCase):
    def test_equality_preserves_string_user_ids(self):
        self.assertEqual(_coerce_value("12", "lecturerUid"), "12")
        self.assertEqual(_coerce_value("12", "createdBy"), "12")

    def test_range_filters_still_coerce_numbers(self):
        self.assertEqual(_coerce_value("3", "year__gte"), 3)

    def test_lecturer_uid_filter_matches_string_json(self):
        ApiDocument.objects.create(
            collection="attendance/lists",
            doc_id="list-1",
            data={"lecturerUid": "12", "createdBy": "12", "program": "day"},
        )
        qs = ApiDocument.objects.filter(collection="attendance/lists")
        from documents.filters import apply_document_filters

        class Params(dict):
            def items(self):
                return super().items()

        filtered = apply_document_filters(qs, {"lecturerUid": "12"})
        self.assertEqual(filtered.count(), 1)
