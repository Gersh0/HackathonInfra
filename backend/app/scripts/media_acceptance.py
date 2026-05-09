import argparse
import json
import urllib.error
import urllib.request


def request_json(url: str) -> tuple[int, dict]:
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=10) as response:
        body = response.read().decode("utf-8")
        return response.status, json.loads(body)


def request_range(url: str, start: int, end: int) -> tuple[int, dict[str, str]]:
    req = urllib.request.Request(url, method="GET")
    req.add_header("Range", f"bytes={start}-{end}")
    with urllib.request.urlopen(req, timeout=10) as response:
        headers = {k.lower(): v for k, v in response.headers.items()}
        return response.status, headers


def request_status(url: str) -> int:
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code


def main() -> None:
    parser = argparse.ArgumentParser(description="Phase 5 media acceptance check")
    parser.add_argument("--api-base-url", default="http://localhost:8000", help="Backend API base URL")
    parser.add_argument("--public-base-url", default="http://localhost", help="Public URL served by nginx")
    args = parser.parse_args()

    api_base = args.api_base_url.rstrip("/")
    public_base = args.public_base_url.rstrip("/")

    status, payload = request_json(f"{api_base}/videos?limit=1&offset=0")
    if status != 200:
        raise SystemExit(f"FAIL: /videos returned status {status}")

    items = payload.get("items") if isinstance(payload, dict) else None
    if not isinstance(items, list) or not items:
        raise SystemExit("FAIL: /videos returned no items to validate")

    video = items[0]
    video_id = int(video["id"])
    stream_url = str(video["stream_url"])
    thumbnail_url = video.get("thumbnail_url")

    if not stream_url.startswith("/uploads/"):
        raise SystemExit(f"FAIL: stream_url does not point to nginx uploads path: {stream_url}")

    if thumbnail_url is not None and not str(thumbnail_url).startswith("/uploads/"):
        raise SystemExit(f"FAIL: thumbnail_url does not point to nginx uploads path: {thumbnail_url}")

    range_status, range_headers = request_range(f"{public_base}{stream_url}", 0, 1023)
    if range_status != 206:
        raise SystemExit(f"FAIL: nginx range request returned {range_status}, expected 206")

    accept_ranges = range_headers.get("accept-ranges", "")
    content_range = range_headers.get("content-range", "")
    if "bytes" not in accept_ranges.lower():
        raise SystemExit("FAIL: Accept-Ranges header missing bytes")
    if not content_range.lower().startswith("bytes "):
        raise SystemExit("FAIL: Content-Range header missing or invalid")

    legacy_status = request_status(f"{api_base}/videos/{video_id}/stream")
    if legacy_status != 404:
        raise SystemExit(f"FAIL: legacy backend stream endpoint returned {legacy_status}, expected 404")

    print("Phase 5 media acceptance: PASS")
    print(f"  video_id={video_id}")
    print(f"  stream_url={stream_url}")
    print(f"  range_status={range_status}")
    print(f"  content_range={content_range}")
    print(f"  legacy_stream_status={legacy_status}")


if __name__ == "__main__":
    main()
