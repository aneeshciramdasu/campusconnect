import unittest
from types import SimpleNamespace
from unittest.mock import patch

from fastapi.testclient import TestClient
from supabase_auth.errors import AuthApiError

from app.main import app


client = TestClient(app)
TEST_EVENT_ID = "550e8400-e29b-41d4-a716-446655440000"


class ProtectedEndpointAuthTests(unittest.TestCase):
    def test_missing_token_is_rejected_for_registration(self):
        response = client.post(
            "/api/registrations",
            json={"event_id": TEST_EVENT_ID},
            headers={"X-User-Id": "forged-user-id"},
        )

        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json()["detail"], "Missing bearer token")

    def test_missing_token_is_rejected_for_my_registrations(self):
        response = client.get(
            "/api/me/registrations",
            headers={"X-User-Id": "forged-user-id"},
        )

        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json()["detail"], "Missing bearer token")

    def test_invalid_token_is_rejected_even_with_forged_user_header(self):
        invalid_token_error = AuthApiError(
            "Invalid JWT",
            status=401,
            code=None,
        )

        with patch(
            "app.auth.supabase.auth.get_user",
            side_effect=invalid_token_error,
        ):
            response = client.get(
                "/api/me/registrations",
                headers={
                    "Authorization": "Bearer invalid-token",
                    "X-User-Id": "forged-user-id",
                },
            )

        self.assertEqual(response.status_code, 401)
        self.assertIn("Invalid or expired", response.json()["detail"])

    def test_malformed_authorization_header_is_rejected(self):
        response = client.get(
            "/api/me/registrations",
            headers={
                "Authorization": "Basic invalid",
                "X-User-Id": "forged-user-id",
            },
        )

        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json()["detail"], "Invalid authorization header")

    def test_attendee_list_requires_token(self):
        response = client.get(
            f"/api/events/{TEST_EVENT_ID}/registrations",
            headers={"X-User-Id": "forged-user-id"},
        )

        self.assertEqual(response.status_code, 401)

    def test_attendee_list_rejects_non_organizer(self):
        verified_user = SimpleNamespace(
            user=SimpleNamespace(id="550e8400-e29b-41d4-a716-446655440001")
        )

        class MappingResponse:
            data = []

        class EventResponse:
            data = [{
                "organizer_id": "11111111-1111-1111-1111-111111111111"
            }]

        with patch(
            "app.auth.supabase.auth.get_user",
            return_value=verified_user,
        ), patch(
            "app.routes.supabase.table",
        ) as table_mock:
            table_mock.side_effect = [
                SimpleNamespace(
                    select=lambda *args, **kwargs: SimpleNamespace(
                        eq=lambda *args, **kwargs: SimpleNamespace(
                            execute=lambda: MappingResponse()
                        )
                    )
                ),
                SimpleNamespace(
                    select=lambda *args, **kwargs: SimpleNamespace(
                        eq=lambda *args, **kwargs: SimpleNamespace(
                            execute=lambda: EventResponse()
                        )
                    )
                ),
            ]
            response = client.get(
                f"/api/events/{TEST_EVENT_ID}/registrations",
                headers={"Authorization": "Bearer valid-test-token"},
            )

        self.assertEqual(response.status_code, 403)

    def test_registration_stays_disabled_by_default(self):
        verified_user = SimpleNamespace(
            user=SimpleNamespace(id="550e8400-e29b-41d4-a716-446655440000")
        )

        with patch(
            "app.auth.supabase.auth.get_user",
            return_value=verified_user,
        ):
            response = client.post(
                "/api/registrations",
                json={"event_id": TEST_EVENT_ID},
                headers={"Authorization": "Bearer valid-test-token"},
            )

        self.assertEqual(response.status_code, 503)
        self.assertEqual(
            response.json()["detail"],
            "Registration is temporarily disabled",
        )


class PublicEndpointTests(unittest.TestCase):
    def test_event_list_remains_public(self):
        response = client.get("/api/events")
        self.assertEqual(response.status_code, 200)
        self.assertIsInstance(response.json(), list)

    def test_event_details_remain_public(self):
        response = client.get(f"/api/events/{TEST_EVENT_ID}")
        self.assertIn(response.status_code, (200, 404))


class CorsTests(unittest.TestCase):
    def test_default_cors_does_not_allow_arbitrary_origin(self):
        response = client.options(
            "/api/events",
            headers={
                "Origin": "https://attacker.example",
                "Access-Control-Request-Method": "GET",
            },
        )

        self.assertNotIn(
            "access-control-allow-origin",
            {key.lower(): value for key, value in response.headers.items()},
        )


if __name__ == "__main__":
    unittest.main()
