import argparse
import json
import time
import tempfile
import uuid
import urllib.error
import urllib.request
from pathlib import Path

from redis import Redis

from app.core.settings import settings


def _request_json(url: str) -> tuple[int, dict]:
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=10) as response:
        body = response.read().decode("utf-8")
        return response.status, json.loads(body)


def _post_json(url: str, payload: dict) -> tuple[int, dict]:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Content-Length", str(len(data)))

    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            body = response.read().decode("utf-8")
            return response.status, json.loads(body)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        parsed = json.loads(body) if body else {}
        return exc.code, parsed


def _multipart_upload(
    url: str,
    title: str,
    description: str,
    file_path: Path,
    access_token: str,
) -> tuple[int, dict, float]:
    boundary = f"----phase6-{uuid.uuid4().hex}"
    file_bytes = file_path.read_bytes()

    parts: list[bytes] = []
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(b'Content-Disposition: form-data; name="title"\r\n\r\n')
    parts.append(title.encode())
    parts.append(b"\r\n")

    parts.append(f"--{boundary}\r\n".encode())
    parts.append(b'Content-Disposition: form-data; name="description"\r\n\r\n')
    parts.append(description.encode())
    parts.append(b"\r\n")

    parts.append(f"--{boundary}\r\n".encode())
    parts.append(
        f'Content-Disposition: form-data; name="file"; filename="{file_path.name}"\r\n'.encode()
    )
    parts.append(b"Content-Type: video/mp4\r\n\r\n")
    parts.append(file_bytes)
    parts.append(b"\r\n")

    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)

    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    req.add_header("Content-Length", str(len(body)))
    req.add_header("Authorization", f"Bearer {access_token}")

    started = time.perf_counter()
    with urllib.request.urlopen(req, timeout=20) as response:
        elapsed_ms = (time.perf_counter() - started) * 1000
        payload = json.loads(response.read().decode("utf-8"))
        return response.status, payload, elapsed_ms


def _build_temp_upload_source(directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    temp_file = directory / f"phase6-source-{uuid.uuid4().hex}.mp4"

    # Keep fixture tiny and isolated from user media; endpoint validates size only.
    temp_file.write_bytes(b"\x00\x00\x00\x18ftypmp42" + b"phase6-test-bytes" * 2048)
    return temp_file


def _wait_for_key(redis: Redis, key: str, timeout_seconds: float) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if redis.exists(key):
            return True
        time.sleep(0.5)
    return False


def _wait_for_hash_field(redis: Redis, key: str, field: str, timeout_seconds: float) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if redis.hexists(key, field):
            return True
        time.sleep(0.5)
    return False


def _wait_for_api(api_base: str, timeout_seconds: float = 30.0) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            status, _ = _request_json(f"{api_base}/health")
            if status == 200:
                return
        except Exception:
            pass
        time.sleep(0.5)
    raise SystemExit("FAIL: backend API not ready before timeout")


def main() -> None:
    parser = argparse.ArgumentParser(description="Phase 6 worker acceptance check")
    parser.add_argument("--api-base-url", default="http://localhost:8000", help="Backend API base URL")
    parser.add_argument("--upload-source", default=None, help="Optional explicit source mp4 path")
    parser.add_argument("--auth-user-id", type=int, default=1, help="User id used to mint JWT for upload")
    parser.add_argument("--job-timeout-seconds", type=float, default=60.0, help="Timeout waiting for worker outputs")
    parser.add_argument("--max-upload-ms", type=float, default=3000.0, help="Upload response threshold in ms")
    args = parser.parse_args()

    api_base = args.api_base_url.rstrip("/")
    redis = Redis.from_url(settings.redis_url)
    _wait_for_api(api_base)

    with tempfile.TemporaryDirectory() as temp_dir:
        source_file = Path(args.upload_source) if args.upload_source else _build_temp_upload_source(Path(temp_dir))

        if not source_file.exists():
            raise SystemExit(f"Upload source not found: {source_file}")

        token_status, token_payload = _post_json(f"{api_base}/auth/token", {"user_id": args.auth_user_id})
        if token_status != 200:
            raise SystemExit(f"FAIL: token issuance failed ({token_status})")
        access_token = str(token_payload.get("access_token", ""))
        if not access_token:
            raise SystemExit("FAIL: token issuance missing access_token")

        title = f"phase6-acceptance-{uuid.uuid4().hex[:8]}"
        status, payload, upload_ms = _multipart_upload(
            f"{api_base}/videos/upload",
            title=title,
            description="phase6 acceptance",
            file_path=source_file,
            access_token=access_token,
        )
        if status != 200:
            raise SystemExit(f"FAIL: upload returned status {status}")

        if upload_ms > args.max_upload_ms:
            raise SystemExit(f"FAIL: upload too slow ({upload_ms:.2f}ms > {args.max_upload_ms:.2f}ms)")

        video_id = int(payload["id"])

        metadata_key = f"worker:video:metadata:{video_id}"
        metadata_ready = _wait_for_key(redis, metadata_key, timeout_seconds=args.job_timeout_seconds)
        if not metadata_ready:
            raise SystemExit(f"FAIL: metadata job output missing for video {video_id}")

        # Trigger analytics aggregation job through view endpoint.
        _request_json(f"{api_base}/videos/{video_id}")

        analytics_ready = _wait_for_hash_field(
            redis,
            key="worker:analytics:video_views",
            field=str(video_id),
            timeout_seconds=args.job_timeout_seconds,
        )
        if not analytics_ready:
            raise SystemExit(f"FAIL: analytics aggregation missing for video {video_id}")

        queue_status, queue_payload = _request_json(f"{api_base}/health/queues")
        if queue_status != 200:
            raise SystemExit(f"FAIL: /health/queues returned status {queue_status}")

        queue_depths = queue_payload.get("queue_depths", {})
        if queue_depths.get("video_processing", 0) != 0 or queue_depths.get("analytics", 0) != 0:
            raise SystemExit(f"FAIL: queue depths not drained: {queue_depths}")

        print("Phase 6 worker acceptance: PASS")
        print(f"  source_file={source_file}")
        print(f"  video_id={video_id}")
        print(f"  upload_elapsed_ms={upload_ms:.2f}")
        print(f"  metadata_key={metadata_key}")
        print(f"  analytics_views={redis.hget('worker:analytics:video_views', str(video_id)).decode()}")
        print(f"  queue_depths={queue_depths}")


if __name__ == "__main__":
    main()
