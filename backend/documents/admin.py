import json

from django.contrib import admin
from django.utils.html import format_html

from .models import ApiDocument


@admin.register(ApiDocument)
class ApiDocumentAdmin(admin.ModelAdmin):
    list_display = (
        "collection",
        "doc_id",
        "summary_preview",
        "updated_at",
        "created_at",
    )
    list_filter = ("collection", "updated_at")
    search_fields = ("collection", "doc_id")
    readonly_fields = ("created_at", "updated_at", "formatted_data")
    date_hierarchy = "updated_at"
    ordering = ("-updated_at",)

    fieldsets = (
        (None, {"fields": ("collection", "doc_id", "data")}),
        ("Preview", {"fields": ("formatted_data",), "classes": ("collapse",)}),
        ("Timestamps", {"fields": ("created_at", "updated_at")}),
    )

    @admin.display(description="Preview")
    def summary_preview(self, obj: ApiDocument) -> str:
        data = obj.data or {}
        if not isinstance(data, dict):
            return str(data)[:80]
        for key in (
            "fullName",
            "title",
            "sessionCode",
            "email",
            "status",
            "registrationNumber",
        ):
            if key in data and data[key]:
                return f"{key}: {data[key]}"[:100]
        text = json.dumps(data, default=str)
        return text[:100] + ("…" if len(text) > 100 else "")

    @admin.display(description="JSON data")
    def formatted_data(self, obj: ApiDocument) -> str:
        pretty = json.dumps(obj.data or {}, indent=2, default=str)
        return format_html("<pre style='max-height:420px;overflow:auto'>{}</pre>", pretty)
