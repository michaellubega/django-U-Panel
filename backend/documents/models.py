from django.db import models


class ApiDocument(models.Model):
    """Schemaless JSON document store (replaces Firestore collections)."""

    collection = models.CharField(max_length=255, db_index=True)
    doc_id = models.CharField(max_length=255)
    data = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["collection", "doc_id"],
                name="documents_unique_collection_doc",
            ),
        ]
        indexes = [
            models.Index(fields=["collection", "updated_at"]),
        ]

    def __str__(self) -> str:
        return f"{self.collection}/{self.doc_id}"
