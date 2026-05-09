import json
import os
import unittest
import uuid
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


BASE_URL = os.getenv("INTEGRATION_BASE_URL", "http://localhost/api").rstrip("/")


class AuthMutationBoundariesIntegrationTest(unittest.TestCase):
    def _request(
        self,
        method: str,
        path: str,
        *,
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
    ):
        req = Request(f"{BASE_URL}{path}", data=data, method=method)
        for key, value in (headers or {}).items():
            req.add_header(key, value)

        try:
            with urlopen(req, timeout=10) as response:
                raw = response.read().decode("utf-8")
                payload = json.loads(raw) if raw else {}
                return response.getcode(), payload
        except HTTPError as exc:
            raw = exc.read().decode("utf-8")
            payload = json.loads(raw) if raw else {}
            return exc.code, payload

    def _create_user(self, display_name: str, provider_subject: str) -> dict:
        body = urlencode(
            {
                "provider": "local",
                "display_name": display_name,
                "provider_subject": provider_subject,
            }
        ).encode("utf-8")
        status, payload = self._request(
            "POST",
            "/users",
            data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        self.assertEqual(status, 200, payload)
        self.assertIn("id", payload)
        return payload

    def _issue_token(self, user_id: int) -> str:
        body = json.dumps({"user_id": user_id}).encode("utf-8")
        status, payload = self._request(
            "POST",
            "/auth/token",
            data=body,
            headers={"Content-Type": "application/json"},
        )
        self.assertEqual(status, 200, payload)
        token = payload.get("access_token")
        self.assertIsInstance(token, str)
        self.assertTrue(token)
        return token

    def test_subscribe_requires_authentication(self):
        suffix = uuid.uuid4().hex[:8]
        user = self._create_user("AuthBoundaryA", f"auth-a-{suffix}")
        creator = self._create_user("AuthBoundaryB", f"auth-b-{suffix}")

        status, payload = self._request(
            "POST", f"/users/{user['id']}/subscriptions/{creator['id']}"
        )
        self.assertEqual(status, 401, payload)
        self.assertEqual(
            payload.get("error", {}).get("message"), "Authentication required"
        )

    def test_subscribe_rejects_token_user_mismatch(self):
        suffix = uuid.uuid4().hex[:8]
        user = self._create_user("MismatchA", f"mismatch-a-{suffix}")
        wrong_token_user = self._create_user("MismatchB", f"mismatch-b-{suffix}")
        creator = self._create_user("MismatchC", f"mismatch-c-{suffix}")

        token = self._issue_token(wrong_token_user["id"])
        status, payload = self._request(
            "POST",
            f"/users/{user['id']}/subscriptions/{creator['id']}",
            headers={"Authorization": f"Bearer {token}"},
        )
        self.assertEqual(status, 403, payload)
        self.assertEqual(payload.get("error", {}).get("message"), "Token user mismatch")

    def test_subscription_endpoints_are_idempotent_for_same_pair(self):
        suffix = uuid.uuid4().hex[:8]
        follower = self._create_user("IdempotentA", f"idempotent-a-{suffix}")
        creator = self._create_user("IdempotentB", f"idempotent-b-{suffix}")
        token = self._issue_token(follower["id"])
        headers = {"Authorization": f"Bearer {token}"}

        first_status, first_payload = self._request(
            "POST",
            f"/users/{follower['id']}/subscriptions/{creator['id']}",
            headers=headers,
        )
        second_status, second_payload = self._request(
            "POST",
            f"/users/{follower['id']}/subscriptions/{creator['id']}",
            headers=headers,
        )

        self.assertEqual(first_status, 200, first_payload)
        self.assertEqual(second_status, 200, second_payload)
        self.assertEqual(first_payload.get("id"), second_payload.get("id"))

        first_delete_status, first_delete_payload = self._request(
            "DELETE",
            f"/users/{follower['id']}/subscriptions/{creator['id']}",
            headers=headers,
        )
        second_delete_status, second_delete_payload = self._request(
            "DELETE",
            f"/users/{follower['id']}/subscriptions/{creator['id']}",
            headers=headers,
        )

        self.assertEqual(first_delete_status, 200, first_delete_payload)
        self.assertEqual(second_delete_status, 200, second_delete_payload)
        self.assertEqual(first_delete_payload.get("status"), "ok")
        self.assertEqual(second_delete_payload.get("status"), "ok")


if __name__ == "__main__":
    unittest.main()
