from django.contrib.auth.models import AbstractUser

from django.db import models





class User(AbstractUser):

    """Extended user profile mirroring former Firestore `app_users` + role docs."""



    class Role(models.TextChoices):

        STUDENT = "student", "Student"

        LECTURER = "lecturer", "Lecturer"

        QA_STAFF = "qa_staff", "QA staff"

        ADMINISTRATOR = "administrator", "Administrator"

        KIU_ADMIN = "kiu_admin", "KIU administrator"



    role = models.CharField(

        max_length=32,

        choices=Role.choices,

        default=Role.STUDENT,

    )

    full_name = models.CharField(max_length=255, blank=True)

    registration_number = models.CharField(max_length=32, blank=True, db_index=True)

    staff_number = models.CharField(max_length=32, blank=True, db_index=True)

    kiu_admin_job_title = models.CharField(max_length=128, blank=True)

    kiu_admin_onboarding_complete = models.BooleanField(default=False)

    email_verified = models.BooleanField(default=False)



    class Meta:

        indexes = [

            models.Index(fields=["registration_number"]),

            models.Index(fields=["staff_number"]),

        ]



    @property

    def is_administrator(self) -> bool:

        return self.role in {

            self.Role.ADMINISTRATOR,

            self.Role.QA_STAFF,

            self.Role.KIU_ADMIN,

        }



    @property

    def is_lecturer(self) -> bool:

        return self.role == self.Role.LECTURER



    @property

    def is_student(self) -> bool:

        return self.role == self.Role.STUDENT





class StudentRegistration(models.Model):

    """One registration number → one user (former `student_registrations`)."""



    registration_number = models.CharField(max_length=32, unique=True)

    user = models.ForeignKey(

        User,

        on_delete=models.CASCADE,

        related_name="registration_claims",

    )

    email_verified_at_link = models.BooleanField(default=False)

    created_at = models.DateTimeField(auto_now_add=True)





class EmailVerificationToken(models.Model):

    """One-time token emailed to verify a mailbox after signup."""



    user = models.ForeignKey(

        User,

        on_delete=models.CASCADE,

        related_name="email_verification_tokens",

    )

    token_hash = models.CharField(max_length=64, db_index=True)

    expires_at = models.DateTimeField()

    used_at = models.DateTimeField(null=True, blank=True)

    created_at = models.DateTimeField(auto_now_add=True)



    class Meta:

        indexes = [

            models.Index(fields=["user", "created_at"]),

        ]





class PushDevice(models.Model):

    """OneSignal player id registered by a client (replaces FCM tokens)."""



    class Platform(models.TextChoices):

        ANDROID = "android", "Android"

        IOS = "ios", "iOS"

        WEB = "web", "Web"

        WINDOWS = "windows", "Windows"

        MACOS = "macos", "macOS"

        LINUX = "linux", "Linux"

        UNKNOWN = "unknown", "Unknown"



    user = models.ForeignKey(

        User,

        on_delete=models.CASCADE,

        related_name="push_devices",

    )

    player_id = models.CharField(max_length=64, unique=True, db_index=True)

    platform = models.CharField(

        max_length=16,

        choices=Platform.choices,

        default=Platform.UNKNOWN,

    )

    tags = models.JSONField(default=dict, blank=True)

    updated_at = models.DateTimeField(auto_now=True)

    created_at = models.DateTimeField(auto_now_add=True)



    class Meta:

        indexes = [

            models.Index(fields=["user", "platform"]),

        ]


