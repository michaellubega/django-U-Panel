from rest_framework import serializers

from .models import PushDevice, StudentRegistration, User


class UserSerializer(serializers.ModelSerializer):
    is_admin = serializers.SerializerMethodField()
    is_qa_staff = serializers.SerializerMethodField()
    is_kiu_admin = serializers.SerializerMethodField()
    is_lecturer = serializers.SerializerMethodField()
    is_student = serializers.SerializerMethodField()

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


class RegisterSerializer(serializers.ModelSerializer):
    password = serializers.CharField(write_only=True, min_length=6)

    class Meta:
        model = User
        fields = ("email", "password", "full_name", "registration_number")

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

    def create(self, validated_data):
        email = validated_data["email"].strip().lower()
        reg = validated_data.get("registration_number") or ""
        user = User.objects.create_user(
            username=email,
            email=email,
            password=validated_data["password"],
            full_name=validated_data.get("full_name", ""),
            registration_number=reg,
            role=User.Role.STUDENT,
        )
        if reg:
            StudentRegistration.objects.update_or_create(
                registration_number=reg,
                defaults={
                    "user": user,
                    "email_verified_at_link": user.email_verified,
                },
            )
        return user


class PushDeviceSerializer(serializers.ModelSerializer):
    class Meta:
        model = PushDevice
        fields = ("player_id", "platform", "tags", "updated_at")
        read_only_fields = fields
