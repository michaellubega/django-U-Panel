import re

from rest_framework import serializers

from .models import PushDevice, StudentRegistration, User

_STAFF_REG_PATTERN = re.compile(r"^KIU\d+[A-Z]$")
_STUDENT_EMAIL_DOMAINS = frozenset({"studmc.kiu.ac.ug", "studwc.kiu.ac.ug"})
_STAFF_EMAIL_DOMAIN = "kiu.ac.ug"
_SELF_REGISTER_ROLES = frozenset(
    {
        User.Role.STUDENT,
        User.Role.LECTURER,
        User.Role.KIU_ADMIN,
    }
)


def _looks_like_staff_registration(reg: str) -> bool:
    return bool(reg and _STAFF_REG_PATTERN.match(reg))


def _is_student_mailbox(email: str) -> bool:
    if "@" not in email:
        return False
    return email.rsplit("@", 1)[-1] in _STUDENT_EMAIL_DOMAINS


def _is_staff_mailbox(email: str) -> bool:
    if _is_student_mailbox(email) or "@" not in email:
        return False
    domain = email.rsplit("@", 1)[-1]
    if domain == _STAFF_EMAIL_DOMAIN:
        return True
    return domain.endswith(".kiu.ac.ug") and domain not in _STUDENT_EMAIL_DOMAINS


class UserSerializer(serializers.ModelSerializer):
    is_admin = serializers.SerializerMethodField()
    is_qa_staff = serializers.SerializerMethodField()
    is_kiu_admin = serializers.SerializerMethodField()
    is_lecturer = serializers.SerializerMethodField()
    is_student = serializers.SerializerMethodField()
    is_oversight = serializers.SerializerMethodField()

    class Meta:
        model = User
        fields = (
            "id",
            "username",
            "email",
            "full_name",
            "role",
            "registration_number",
            "staff_number",
            "kiu_admin_job_title",
            "kiu_admin_onboarding_complete",
            "email_verified",
            "is_admin",
            "is_qa_staff",
            "is_kiu_admin",
            "is_lecturer",
            "is_student",
            "is_oversight",
        )
        read_only_fields = fields

    def get_is_admin(self, obj: User) -> bool:
        return obj.is_administrator

    def get_is_qa_staff(self, obj: User) -> bool:
        return obj.role == User.Role.QA_STAFF

    def get_is_kiu_admin(self, obj: User) -> bool:
        return obj.role == User.Role.KIU_ADMIN

    def get_is_lecturer(self, obj: User) -> bool:
        return obj.is_lecturer

    def get_is_student(self, obj: User) -> bool:
        return obj.is_student

    def get_is_oversight(self, obj: User) -> bool:
        return obj.is_oversight


class RegisterSerializer(serializers.ModelSerializer):
    password = serializers.CharField(write_only=True, min_length=6)
    role = serializers.CharField(required=False, allow_blank=True, write_only=True)

    class Meta:
        model = User
        fields = ("email", "password", "full_name", "registration_number", "role")

    def validate_email(self, value: str) -> str:
        email = (value or "").strip().lower()
        if User.objects.filter(email=email).exists():
            raise serializers.ValidationError(
                "An account already exists for that email."
            )
        return email

    def validate_registration_number(self, value: str) -> str:
        reg = (value or "").strip().upper()
        if not reg:
            return ""
        if User.objects.filter(registration_number=reg).exists():
            raise serializers.ValidationError(
                "That registration number is already linked to another account."
            )
        if StudentRegistration.objects.filter(registration_number=reg).exists():
            raise serializers.ValidationError(
                "That registration number is already linked to another account."
            )
        return reg

    def validate_role(self, value: str) -> str:
        role = (value or "").strip().lower()
        if not role:
            return ""
        if role == "staff":
            role = User.Role.LECTURER
        if role not in _SELF_REGISTER_ROLES:
            raise serializers.ValidationError(
                "Choose student or lecturer before creating the account."
            )
        return role

    def validate(self, attrs):
        email = (attrs.get("email") or "").strip().lower()
        reg = (attrs.get("registration_number") or "").strip().upper()
        role = (attrs.get("role") or "").strip().lower()
        staff_shaped = _is_staff_mailbox(email) and _looks_like_staff_registration(reg)

        if staff_shaped and not role:
            raise serializers.ValidationError(
                {
                    "role": (
                        "These details look like a KIU staff account "
                        "(@kiu.ac.ug + KIU staff ID). Choose student or lecturer "
                        "before creating the account."
                    )
                }
            )

        if not role:
            role = User.Role.STUDENT

        if role == User.Role.STUDENT:
            if staff_shaped:
                raise serializers.ValidationError(
                    {
                        "role": (
                            "A @kiu.ac.ug email with a KIU staff ID cannot be "
                            "registered as a student. Choose lecturer, or use your "
                            "student email (@studmc.kiu.ac.ug / @studwc.kiu.ac.ug) "
                            "and student registration number."
                        )
                    }
                )
        elif role in {User.Role.LECTURER, User.Role.KIU_ADMIN}:
            if not _is_staff_mailbox(email):
                raise serializers.ValidationError(
                    {
                        "email": (
                            "Lecturer / staff accounts must use an official "
                            "@kiu.ac.ug email."
                        )
                    }
                )
            if not _looks_like_staff_registration(reg):
                raise serializers.ValidationError(
                    {
                        "registration_number": (
                            "Use your KIU staff ID (e.g. KIU1234S)."
                        )
                    }
                )

        attrs["role"] = role
        attrs["registration_number"] = reg
        return attrs

    def create(self, validated_data):
        email = validated_data["email"].strip().lower()
        reg = validated_data.get("registration_number") or ""
        role = validated_data.get("role") or User.Role.STUDENT
        staff_number = reg if role in {User.Role.LECTURER, User.Role.KIU_ADMIN} else ""
        user = User.objects.create_user(
            username=email,
            email=email,
            password=validated_data["password"],
            full_name=validated_data.get("full_name", ""),
            registration_number=reg,
            staff_number=staff_number,
            role=role,
            kiu_admin_onboarding_complete=(role == User.Role.KIU_ADMIN),
        )
        if role == User.Role.STUDENT and reg:
            StudentRegistration.objects.update_or_create(
                registration_number=reg,
                defaults={
                    "user": user,
                    "email_verified_at_link": user.email_verified,
                },
            )
        return user


_OVERSIGHT_ROLES = frozenset(
    {
        User.Role.VC,
        User.Role.DVC,
        User.Role.DQA,
        User.Role.DEAN,
        User.Role.HOD,
    }
)


class ProvisionOversightSerializer(serializers.Serializer):
    """Admin-only: create a read-only leadership account (VC / DQA / Dean / HOD)."""

    email = serializers.EmailField()
    password = serializers.CharField(write_only=True, min_length=6)
    full_name = serializers.CharField(max_length=255)
    role = serializers.ChoiceField(choices=sorted(_OVERSIGHT_ROLES))
    staff_number = serializers.CharField(required=False, allow_blank=True)

    def validate_email(self, value: str) -> str:
        email = (value or "").strip().lower()
        if User.objects.filter(email=email).exists():
            raise serializers.ValidationError(
                "An account already exists for that email."
            )
        return email

    def create(self, validated_data):
        email = validated_data["email"]
        staff = (validated_data.get("staff_number") or "").strip().upper()
        user = User.objects.create_user(
            username=email,
            email=email,
            password=validated_data["password"],
            full_name=validated_data["full_name"],
            staff_number=staff,
            registration_number=staff,
            role=validated_data["role"],
            email_verified=True,
        )
        return user


class PushDeviceSerializer(serializers.ModelSerializer):
    class Meta:
        model = PushDevice
        fields = ("player_id", "platform", "tags", "updated_at")
        read_only_fields = fields
