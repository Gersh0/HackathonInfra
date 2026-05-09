import argparse
import json
import urllib.request


def get_json(url: str) -> tuple[int, dict]:
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=10) as response:
        return response.status, json.loads(response.read().decode("utf-8"))


def get_status(url: str, headers: dict[str, str] | None = None) -> int:
    req = urllib.request.Request(url, method="GET")
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    with urllib.request.urlopen(req, timeout=10) as response:
        return response.status


def main() -> None:
    parser = argparse.ArgumentParser(description="Phase 7 frontend acceptance smoke check")
    parser.add_argument("--public-base-url", default="http://nginx", help="Public app URL")
    parser.add_argument("--api-base-url", default="http://backend:8000", help="Backend API URL")
    args = parser.parse_args()

    public_base = args.public_base_url.rstrip("/")
    api_base = args.api_base_url.rstrip("/")

    route_statuses = {
        "/": get_status(f"{public_base}/", headers={"Host": "localhost"}),
        "/users": get_status(f"{public_base}/users", headers={"Host": "localhost"}),
        "/subscriptions": get_status(f"{public_base}/subscriptions", headers={"Host": "localhost"}),
    }

    for route, status in route_statuses.items():
        if status != 200:
            raise SystemExit(f"FAIL: route {route} returned {status}")

    videos_status, videos_payload = get_json(f"{api_base}/videos?limit=5&offset=0&q=test")
    users_status, users_payload = get_json(f"{api_base}/users?limit=5&offset=0&q=test")

    if videos_status != 200:
        raise SystemExit(f"FAIL: /videos pagination request returned {videos_status}")
    if users_status != 200:
        raise SystemExit(f"FAIL: /users pagination request returned {users_status}")

    video_items = videos_payload.get("items", []) if isinstance(videos_payload, dict) else []
    user_items = users_payload.get("items", []) if isinstance(users_payload, dict) else []

    if not isinstance(video_items, list) or len(video_items) > 5:
        raise SystemExit("FAIL: /videos did not return bounded paginated items")
    if not isinstance(user_items, list) or len(user_items) > 5:
        raise SystemExit("FAIL: /users did not return bounded paginated items")

    if video_items:
        stream_url = video_items[0].get("stream_url")
        if not isinstance(stream_url, str) or not stream_url.startswith("/api/videos/"):
            raise SystemExit("FAIL: frontend video payload is not using protected media API URLs")

    # Offset probe to ensure load-more pages are available consistently.
    next_status, next_payload = get_json(f"{api_base}/videos?limit=5&offset=5")
    if next_status != 200 or not isinstance(next_payload, dict):
        raise SystemExit("FAIL: /videos next-page probe failed")

    print("Phase 7 frontend acceptance: PASS")
    print(f"  routes={route_statuses}")
    print(f"  videos_count_page1={len(video_items)}")
    print(f"  users_count_page1={len(user_items)}")
    print("  pagination_and_search_params=ok")


if __name__ == "__main__":
    main()
