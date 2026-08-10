from django.test import TestCase, override_settings


class ClientConfigTests(TestCase):
  def test_returns_empty_when_unconfigured(self):
    response = self.client.get("/api/client-config/")
    self.assertEqual(response.status_code, 200)
    data = response.json()
    self.assertEqual(data["onesignal_app_id"], "")
    self.assertFalse(data["push_enabled"])

  @override_settings(ONESIGNAL_APP_ID="11111111-2222-3333-4444-555555555555")
  def test_returns_onesignal_app_id(self):
    response = self.client.get("/api/client-config/")
    self.assertEqual(response.status_code, 200)
    data = response.json()
    self.assertEqual(data["onesignal_app_id"], "11111111-2222-3333-4444-555555555555")
    self.assertTrue(data["push_enabled"])
