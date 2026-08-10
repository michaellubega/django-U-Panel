from django.test import TestCase

from accounts.models import User
from accounts.services.login_identifier import (
    normalize_staff_number,
    resolve_user_for_login,
    synthetic_email_for_staff_number,
)


class LoginIdentifierTests(TestCase):
    def test_normalize_staff_number(self):
        self.assertEqual(normalize_staff_number("kiu-0001"), "KIU-0001")
        self.assertEqual(normalize_staff_number("KIU0001"), "KIU-0001")
        self.assertEqual(normalize_staff_number("0001"), "KIU-0001")
        self.assertIsNone(normalize_staff_number("KIU3454S"))

    def test_synthetic_email(self):
        self.assertEqual(
            synthetic_email_for_staff_number("KIU-0001"),
            "kiu0001@staff.upanel.local",
        )

    def test_resolve_by_registration_number(self):
        User.objects.create_user(
            username="staff@kiu.ac.ug",
            email="staff@kiu.ac.ug",
            password="secret12",
            registration_number="KIU3454S",
        )
        user = resolve_user_for_login("kiu3454s")
        self.assertIsNotNone(user)
        self.assertEqual(user.email, "staff@kiu.ac.ug")

    def test_resolve_by_staff_number(self):
        User.objects.create_user(
            username="kiu0001@staff.upanel.local",
            email="kiu0001@staff.upanel.local",
            password="secret12",
            staff_number="KIU-0001",
        )
        user = resolve_user_for_login("KIU0001")
        self.assertIsNotNone(user)
        self.assertEqual(user.staff_number, "KIU-0001")
