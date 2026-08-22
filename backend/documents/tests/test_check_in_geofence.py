from django.test import TestCase

from documents.services.check_in import GEOFENCE_BUFFER_METERS, _within_geofence


class CheckInGeofenceTests(TestCase):
    def _session(self, **overrides):
        data = {
            "latitude": 0.3476,
            "longitude": 32.5825,
            "radiusMeters": 50,
        }
        data.update(overrides)
        return data

    def _attempt(self, **overrides):
        data = {
            "latitude": 0.3476,
            "longitude": 32.5826,
        }
        data.update(overrides)
        return data

    def test_accepts_coordinates_within_radius_plus_buffer(self) -> None:
        self.assertTrue(
            _within_geofence(self._session(), self._attempt()),
        )

    def test_rejects_coordinates_outside_radius_plus_buffer(self) -> None:
        self.assertFalse(
            _within_geofence(
                self._session(radiusMeters=25),
                self._attempt(latitude=0.36, longitude=32.60),
            ),
        )

    def test_skips_when_remote_learning(self) -> None:
        self.assertTrue(
            _within_geofence(
                self._session(remoteLearning=True, radiusMeters=1),
                self._attempt(latitude=0.0, longitude=0.0),
            ),
        )

    def test_skips_when_location_metadata_pending(self) -> None:
        self.assertTrue(
            _within_geofence(
                self._session(locationMetadataPending=True),
                self._attempt(latitude=0.36, longitude=32.60),
            ),
        )

    def test_skips_when_session_center_unset(self) -> None:
        self.assertTrue(
            _within_geofence(
                self._session(latitude=0.0, longitude=0.0),
                self._attempt(),
            ),
        )

    def test_rejects_student_coordinates_at_null_island(self) -> None:
        self.assertFalse(
            _within_geofence(self._session(), self._attempt(latitude=0.0, longitude=0.0)),
        )

    def test_buffer_applies_at_boundary(self) -> None:
        session = self._session(radiusMeters=50)
        # ~60 m north of centre — inside 50 + buffer, outside raw radius.
        attempt = self._attempt(latitude=0.34814, longitude=32.5825)
        self.assertTrue(_within_geofence(session, attempt))
        self.assertEqual(GEOFENCE_BUFFER_METERS, 25)

    def test_student_gps_accuracy_adds_tolerance(self) -> None:
        session = self._session(radiusMeters=25)
        # ~60 m north — outside 25+25 buffer but inside when student accuracy is 60 m.
        attempt = self._attempt(
            latitude=0.34814,
            longitude=32.5825,
            gpsAccuracyMeters=60,
        )
        self.assertTrue(_within_geofence(session, attempt))
        self.assertFalse(
            _within_geofence(
                session,
                self._attempt(latitude=0.34814, longitude=32.5825),
            ),
        )
