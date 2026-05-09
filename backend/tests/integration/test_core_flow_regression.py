import json
import os
import unittest
import uuid
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


BASE_URL = os.getenv("INTEGRATION_BASE_URL", "http://localhost/api").rstrip("/")


class CoreFlowRegressionIntegrationTest(unittest.TestCase):
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
            with urlopen(req, timeout=15) as response:
                raw = response.read().decode("utf-8")
                payload = json.loads(raw) if raw else {}
                return response.getcode(), payload
        except HTTPError as exc:
            raw = exc.read().decode("utf-8")
            payload = json.loads(raw) if raw else {}
            return exc.code, payload

    def _request_raw(
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

        with urlopen(req, timeout=15) as response:
            return response.getcode(), dict(response.headers.items()), response.read()

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

    def _build_multipart_upload(
        self, *, title: str, description: str, video_name: str, video_bytes: bytes
    ) -> tuple[bytes, str]:
        boundary = f"----Boundary{uuid.uuid4().hex}"
        parts: list[bytes] = []

        def add_field(name: str, value: str) -> None:
            parts.append(
                (
                    f"--{boundary}\r\n"
                    f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                    f"{value}\r\n"
                ).encode("utf-8")
            )

        def add_file(
            name: str, filename: str, content_type: str, content: bytes
        ) -> None:
            header = (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
                f"Content-Type: {content_type}\r\n\r\n"
            ).encode("utf-8")
            parts.append(header + content + b"\r\n")

        add_field("title", title)
        add_field("description", description)
        add_file("file", video_name, "video/mp4", video_bytes)
        parts.append(f"--{boundary}--\r\n".encode("utf-8"))

        content_type = f"multipart/form-data; boundary={boundary}"
        return b"".join(parts), content_type

    def test_upload_watch_comment_subscribe_delete_flow(self):
        suffix = uuid.uuid4().hex[:8]
        uploader = self._create_user("FlowUploader", f"flow-uploader-{suffix}")
        follower = self._create_user("FlowFollower", f"flow-follower-{suffix}")

        uploader_token = self._issue_token(uploader["id"])
        follower_token = self._issue_token(follower["id"])

        subscribe_status, subscribe_payload = self._request(
            "POST",
            f"/users/{follower['id']}/subscriptions/{uploader['id']}",
            headers={"Authorization": f"Bearer {follower_token}"},
        )
        self.assertEqual(subscribe_status, 200, subscribe_payload)

        upload_body, upload_content_type = self._build_multipart_upload(
            title="Regression Video",
            description="Core integration flow",
            video_name="flow.mp4",
            video_bytes=b"\x00\x00\x00\x20ftypisom\x00\x00\x02\x00isomiso2",
        )
        upload_status, upload_payload = self._request(
            "POST",
            "/videos/upload",
            data=upload_body,
            headers={
                "Authorization": f"Bearer {uploader_token}",
                "Content-Type": upload_content_type,
            },
        )
        self.assertEqual(upload_status, 200, upload_payload)
        video_id = int(upload_payload["id"])
        self.assertEqual(
            upload_payload.get("stream_url"), f"/api/videos/{video_id}/stream"
        )

        stream_status, stream_headers, stream_body = self._request_raw(
            "GET", f"/videos/{video_id}/stream"
        )
        self.assertEqual(stream_status, 200)
        self.assertGreater(len(stream_body), 0)
        self.assertIn("accept-ranges", {key.lower() for key in stream_headers})

        feed_status, feed_payload = self._request(
            "GET",
            f"/users/{follower['id']}/feed?limit=20&offset=0",
        )
        self.assertEqual(feed_status, 200, feed_payload)
        self.assertTrue(
            any(int(item["id"]) == video_id for item in feed_payload.get("items", [])),
            feed_payload,
        )

        watch_status, watch_payload = self._request("GET", f"/videos/{video_id}")
        self.assertEqual(watch_status, 200, watch_payload)
        self.assertGreaterEqual(int(watch_payload.get("views", 0)), 1)

        comment_body = json.dumps({"content": "looks good"}).encode("utf-8")
        comment_status, comment_payload = self._request(
            "POST",
            f"/videos/{video_id}/comments",
            data=comment_body,
            headers={
                "Authorization": f"Bearer {follower_token}",
                "Content-Type": "application/json",
            },
        )
        self.assertEqual(comment_status, 200, comment_payload)
        self.assertEqual(int(comment_payload["video_id"]), video_id)

        delete_status, delete_payload = self._request(
            "DELETE",
            f"/videos/{video_id}",
            headers={"Authorization": f"Bearer {uploader_token}"},
        )
        self.assertEqual(delete_status, 200, delete_payload)
        self.assertEqual(delete_payload.get("status"), "ok")

        get_deleted_status, get_deleted_payload = self._request(
            "GET", f"/videos/{video_id}"
        )
        self.assertEqual(get_deleted_status, 404, get_deleted_payload)


if __name__ == "__main__":
    unittest.main()
