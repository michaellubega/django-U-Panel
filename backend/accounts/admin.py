from django.contrib import admin, messages
from django.contrib.auth.admin import UserAdmin as DjangoUserAdmin
from django.utils import timezone

from .models import EmailVerificationToken, PushDevice, StudentRegistration, User


@admin.action(description="Mark selected users' email as verified")
def mark_email_verified(modeladmin, request, queryset):
    updated = queryset.update(email_verified=True)
    for user in queryset:
        StudentRegistration.objects.filter(user=user).update(email_verified_at_link=True)
    messages.success(request, f"Marked {updated} user(s) as email verified.")


@admin.register(User)
class UserAdmin(DjangoUserAdmin):
    actions = [mark_email_verified]
    ordering = ("-date_joined",)
    date_hierarchy = "date_joined"
    search_fields = (
        "username",
        "email",
        "full_name",
        "registration_number",
        "staff_number",
    )
    list_display = (
        "full_name",
        "email",
        "role",
        "registration_number",
        "staff_number",
        "email_verified",
        "is_active",
        "date_joined",
    )
    list_filter = ("role", "is_active", "is_staff", "email_verified")
    list_select_related = ()
    fieldsets = DjangoUserAdmin.fieldsets + (
        (
            "U-Panel profile",
            {
                "fields": (
                    "role",
                    "full_name",
                    "registration_number",
                    "staff_number",
                    "kiu_admin_job_title",
                    "kiu_admin_onboarding_complete",
                    "email_verified",
                ),
            },
        ),
    )
    add_fieldsets = DjangoUserAdmin.add_fieldsets + (
        (
            "U-Panel profile",
            {
                "classes": ("wide",),
                "fields": (
                    "role",
                    "full_name",
                    "registration_number",
                    "staff_number",
                    "email_verified",
                ),
            },
        ),
    )


@admin.register(EmailVerificationToken)
class EmailVerificationTokenAdmin(admin.ModelAdmin):
    list_display = ("user", "expires_at", "used_at", "is_valid_display", "created_at")
    list_filter = ("used_at", "expires_at")
    search_fields = ("user__email", "user__full_name")
    readonly_fields = ("token_hash", "created_at")
    raw_id_fields = ("user",)
    date_hierarchy = "created_at"

    @admin.display(boolean=True, description="Valid")
    def is_valid_display(self, obj: EmailVerificationToken) -> bool:
        return obj.used_at is None and obj.expires_at > timezone.now()


@admin.register(StudentRegistration)
class StudentRegistrationAdmin(admin.ModelAdmin):
    list_display = (
        "registration_number",
        "user",
        "user_email",
        "email_verified_at_link",
        "created_at",
    )
    list_filter = ("email_verified_at_link", "created_at")
    search_fields = ("registration_number", "user__email", "user__full_name")
    raw_id_fields = ("user",)
    date_hierarchy = "created_at"

    @admin.display(description="Email")
    def user_email(self, obj: StudentRegistration) -> str:
        return obj.user.email if obj.user_id else "—"


@admin.register(PushDevice)
class PushDeviceAdmin(admin.ModelAdmin):
    list_display = ("player_id", "user", "platform", "updated_at")
    search_fields = ("player_id", "user__email", "user__full_name")
    list_filter = ("platform", "updated_at")
    raw_id_fields = ("user",)
    readonly_fields = ("created_at", "updated_at")
