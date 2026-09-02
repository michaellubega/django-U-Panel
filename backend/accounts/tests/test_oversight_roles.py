"""Oversight roles read attendance and cannot change capture data."""

from django.test import TestCase
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from accounts.models import User
from documents.models import ApiDocument


class OversightRoleTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.admin = User.objects.create_user(
            username="admin@kiu.ac.ug",
            email="admin@kiu.ac.ug",
            password="secret12",
            role=User.Role.ADMINISTRATOR,
            full_name="Admin User",
        )
        self.vc = User.objects.create_user(
            username="vc@kiu.ac.ug",
            email="vc@kiu.ac.ug",
            password="secret12",
            role=User.Role.VC,
            full_name="Vice Chancellor",
        )
        ApiDocument.objects.update_or_create(
            collection="attendance/lists",
            doc_id="list-1",
            defaults={"data": {"whoTaught": "Dr Test", "room": "A1"}},
        )

    def test_me_exposes_oversight_flag(self):
        token, _ = Token.objects.get_or_create(user=self.vc)
        self.client.credentials(HTTP_AUTHORIZATION=f"Token {token.key}")
        response = self.client.get("/api/auth/me/")
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["role"], "vc")
        self.assertTrue(body["is_oversight"])
        self.assertFalse(body["is_admin"])
        self.assertFalse(body["is_lecturer"])

    def test_vc_can_read_attendance_lists(self):
        token, _ = Token.objects.get_or_create(user=self.vc)
        self.client.credentials(HTTP_AUTHORIZATION=f"Token {token.key}")
        response = self.client.get("/api/attendance/lists/")
        self.assertEqual(response.status_code, 200)
        self.assertGreaterEqual(len(response.json()), 1)

    def test_vc_cannot_write_attendance(self):
        token, _ = Token.objects.get_or_create(user=self.vc)
        self.client.credentials(HTTP_AUTHORIZATION=f"Token {token.key}")
        response = self.client.post(
            "/api/attendance/lists/",
            {"id": "should-fail", "whoTaught": "Nope"},
            format="json",
        )
        self.assertEqual(response.status_code, 403)
        self.assertFalse(
            ApiDocument.objects.filter(
                collection="attendance/lists", doc_id="should-fail"
            ).exists()
        )

    def test_admin_can_provision_dean(self):
        token, _ = Token.objects.get_or_create(user=self.admin)
        self.client.credentials(HTTP_AUTHORIZATION=f"Token {token.key}")
        response = self.client.post(
            "/api/auth/provision-oversight/",
            {
                "email": "dean@kiu.ac.ug",
                "password": "secret12",
                "full_name": "Dean Of Science",
                "role": "dean",
                "staff_number": "KIU-8801",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 201, response.content)
        user = User.objects.get(email="dean@kiu.ac.ug")
        self.assertEqual(user.role, User.Role.DEAN)
        self.assertTrue(user.is_oversight)
        self.assertFalse(user.is_administrator)

    def test_vc_cannot_provision_oversight(self):
        token, _ = Token.objects.get_or_create(user=self.vc)
        self.client.credentials(HTTP_AUTHORIZATION=f"Token {token.key}")
        response = self.client.post(
            "/api/auth/provision-oversight/",
            {
                "email": "hod@kiu.ac.ug",
                "password": "secret12",
                "full_name": "Head",
                "role": "hod",
            },
            format="json",
        )
        self.assertEqual(response.status_code, 403)
        self.assertFalse(User.objects.filter(email="hod@kiu.ac.ug").exists())
