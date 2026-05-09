import argparse
import json
import time
import urllib.error
import urllib.request
import uuid

from redis import Redis

from app.core.settings import settings


def _json_request(
    url: str,
    method: str = "GET",
    body: dict | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, dict, dict[str, str]]:
    payload = None
    merged_headers = {"Content-Type": "application/json"} if body is not None else {}
    if headers:
        merged_headers.update(headers)
    if body is not None:
        payload = json.dumps(body).encode("utf-8")

    req = urllib.request.Request(url=url, method=method, data=payload, headers=merged_headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            raw = response.read().decode("utf-8")
            parsed = json.loads(raw) if raw else {}
            response_headers = {k.lower(): v for k, v in response.headers.items()}
            return response.status, parsed, response_headers
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        parsed = json.loads(raw) if raw else {}
        response_headers = {k.lower(): v for k, v in exc.headers.items()}
        return exc.code, parsed, response_headers


def _multipart_user_create(url: str, display_name: str) -> int:
    boundary = f"----phase8-{uuid.uuid4().hex}"
    parts: list[bytes] = []

    parts.append(f"--{boundary}\r\n".encode())
    parts.append(b'Content-Disposition: form-data; name="display_name"\r\n\r\n')
    parts.append(display_name.encode())
    parts.append(b"\r\n")

    parts.append(f"--{boundary}\r\n".encode())
    parts.append(b'Content-Disposition: form-data; name="provider"\r\n\r\n')
    parts.append(b"local")
    parts.append(b"\r\n")

    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)

    req = urllib.request.Request(url=url, method="POST", data=body)
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    req.add_header("Content-Length", str(len(body)))

    with urllib.request.urlopen(req, timeout=15) as response:
        payload = json.loads(response.read().decode("utf-8"))
        return int(payload["id"])


def _oversized_auth_probe(url: str, size_bytes: int) -> int:
    body = b"a" * size_bytes
    req = urllib.request.Request(url=url, method="POST", data=body)
    req.add_header("Content-Type", "application/json")
    req.add_header("Content-Length", str(len(body)))
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except urllib.error.URLError as exc:
        # Some servers terminate oversized uploads by resetting the connection
        # before emitting a structured HTTP response.
        if isinstance(exc.reason, ConnectionResetError):
            return 413
        raise


def _clear_ratelimit_keys() -> int:
    redis = Redis.from_url(settings.redis_url)
    keys = list(redis.scan_iter(match="ratelimit:*", count=200))
    if not keys:
        return 0
    return int(redis.delete(*keys))


def _wait_for_api(base_url: str, timeout_seconds: int = 45) -> None:
    deadline = time.time() + timeout_seconds
    last_error: Exception | None = None

    while time.time() < deadline:
        try:
            status, _, _ = _json_request(f"{base_url}/health")
            if status == 200:
                return
        except urllib.error.URLError as exc:
            last_error = exc
        time.sleep(0.5)

    if last_error:
        raise SystemExit(f"FAIL: backend not reachable before timeout ({last_error})")
    raise SystemExit("FAIL: backend health did not become ready before timeout")


def main() -> None:
    parser = argparse.ArgumentParser(description="Phase 8 security acceptance check")
    parser.add_argument("--api-base-url", default="http://localhost:8000", help="Backend API base URL")
    args = parser.parse_args()

    api_base = args.api_base_url.rstrip("/")
    _wait_for_api(api_base)

    cleared = _clear_ratelimit_keys()
    print(f"cleared_ratelimit_keys={cleared}")

    users_status, users_payload, _ = _json_request(f"{api_base}/users?limit=2&offset=0")
    if users_status != 200:
        raise SystemExit(f"FAIL: users listing unavailable ({users_status})")

    users = users_payload.get("items", []) if isinstance(users_payload, dict) else []
    while len(users) < 2:
        new_id = _multipart_user_create(f"{api_base}/users", display_name=f"phase8-{uuid.uuid4().hex[:8]}")
        users.append({"id": new_id})

    user_a = int(users[0]["id"])
    user_b = int(users[1]["id"])

    token_status, token_payload, _ = _json_request(
        f"{api_base}/auth/token", method="POST", body={"user_id": user_a}
    )
    if token_status != 200:
        raise SystemExit(f"FAIL: token issuance failed ({token_status})")
    access_token = str(token_payload.get("access_token", ""))
    if not access_token:
        raise SystemExit("FAIL: token issuance response missing access_token")

    videos_status, videos_payload, _ = _json_request(f"{api_base}/videos?limit=1&offset=0")
    if videos_status != 200:
        raise SystemExit(f"FAIL: videos listing unavailable ({videos_status})")
    videos = videos_payload.get("items", []) if isinstance(videos_payload, dict) else []
    if not videos:
        raise SystemExit("FAIL: no video exists for comment auth test")
    video_id = int(videos[0]["id"])

    unauth_status, _, _ = _json_request(
        f"{api_base}/videos/{video_id}/comments",
        method="POST",
        body={"content": "security acceptance unauth"},
    )
    if unauth_status != 401:
        raise SystemExit(f"FAIL: unauthenticated mutation expected 401, got {unauth_status}")

    auth_status, _, _ = _json_request(
        f"{api_base}/videos/{video_id}/comments",
        method="POST",
        body={"content": "security acceptance auth"},
        headers={"Authorization": f"Bearer {access_token}"},
    )
    if auth_status != 200:
        raise SystemExit(f"FAIL: authenticated comment mutation failed ({auth_status})")

    mismatch_status, _, _ = _json_request(
        f"{api_base}/users/{user_b}/subscriptions/{user_a}",
        method="POST",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    if mismatch_status != 403:
        raise SystemExit(f"FAIL: token mismatch mutation expected 403, got {mismatch_status}")

    cors_status, _, cors_headers = _json_request(
        f"{api_base}/health",
        headers={"Origin": "http://localhost:5173"},
    )
    if cors_status != 200:
        raise SystemExit(f"FAIL: cors probe failed ({cors_status})")
    allow_origin = cors_headers.get("access-control-allow-origin", "")
    if allow_origin != "http://localhost:5173":
        raise SystemExit(f"FAIL: cors origin mismatch ({allow_origin!r})")

    oversized_status = _oversized_auth_probe(
        f"{api_base}/auth/token",
        size_bytes=settings.max_request_body_bytes + 1024,
    )
    if oversized_status != 413:
        raise SystemExit(f"FAIL: oversized payload expected 413, got {oversized_status}")

    last_status = 200
    for _ in range(settings.rate_limit_auth_max_requests + 5):
        status, _, _ = _json_request(
            f"{api_base}/auth/token",
            method="POST",
            body={"user_id": user_a},
        )
        last_status = status
        if status == 429:
            break
        time.sleep(0.02)

    if last_status != 429:
        raise SystemExit(f"FAIL: auth rate limit expected 429, got {last_status}")

    print("Phase 8 security acceptance: PASS")
    print(f"  user_a={user_a} user_b={user_b} video_id={video_id}")
    print("  checks=401,200,403,CORS,413,429")


if __name__ == "__main__":
    main()
