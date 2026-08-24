"""Self-registration must not force student role for staff credentials."""

from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import StudentRegistration, User


class RegisterRoleChoiceTests(TestCase):
    def setUp(self):
        self.client = APIClient()

    def test_default_register_is_student(self):
        response = self.client.post(
            "/api/auth/register/",
            {
                "email": "jane.doe@studmc.kiu.ac.ug",
                "password": "secret12",
                "full_name": "Jane Doe",
                "registration_number": "2025-08-41310",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201)
        user = User.objects.get(email="jane.doe@studmc.kiu.ac.ug")
        self.assertEqual(user.role, User.Role.STUDENT)
        self.assertTrue(
            StudentRegistration.objects.filter(
                registration_number="2025-08-41310"
            ).exists()
        )

    def test_staff_credentials_as_lecturer_when_role_requested(self):
        response = self.client.post(
            "/api/auth/register/",
            {
                "email": "jane.doe@kiu.ac.ug",
                "password": "secret12",
                "full_name": "Jane Doe",
                "registration_number": "KIU1234S",
                "role": "lecturer",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.content)
        body = response.json()
        self.assertEqual(body["user"]["role"], "lecturer")
        self.assertTrue(body["user"]["is_lecturer"])
        self.assertFalse(body["user"]["is_student"])
        user = User.objects.get(email="jane.doe@kiu.ac.ug")
        self.assertEqual(user.role, User.Role.LECTURER)
        self.assertEqual(user.registration_number, "KIU1234S")
        self.assertEqual(user.staff_number, "KIU1234S")
        self.assertFalse(
            StudentRegistration.objects.filter(
                registration_number="KIU1234S"
            ).exists()
        )

    def test_staff_credentials_without_role_do_not_auto_become_student_silently(self):
        """@kiu.ac.ug + KIU####S requires an explicit role choice."""
        response = self.client.post(
            "/api/auth/register/",
            {
                "email": "lecturer@kiu.ac.ug",
                "password": "secret12",
                "full_name": "Lee Cturer",
                "registration_number": "KIU1234S",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 400)
        self.assertFalse(User.objects.filter(email="lecturer@kiu.ac.ug").exists())

    def test_cannot_self_register_as_admin(self):
        response = self.client.post(
            "/api/auth/register/",
            {
                "email": "boss@kiu.ac.ug",
                "password": "secret12",
                "full_name": "Boss",
                "registration_number": "KIU9999S",
                "role": "administrator",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 400)
        self.assertFalse(User.objects.filter(email="boss@kiu.ac.ug").exists())

    def test_kiu_admin_role_allowed_for_staff_credentials(self):
        response = self.client.post(
            "/api/auth/register/",
            {
                "email": "admin.person@kiu.ac.ug",
                "password": "secret12",
                "full_name": "Admin Person",
                "registration_number": "KIU4235S",
                "role": "kiu_admin",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.content)
        user = User.objects.get(email="admin.person@kiu.ac.ug")
        self.assertEqual(user.role, User.Role.KIU_ADMIN)
        self.assertFalse(
            StudentRegistration.objects.filter(
                registration_number="KIU4235S"
            ).exists()
        )
