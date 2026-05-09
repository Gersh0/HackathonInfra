import argparse
import json
import time
import urllib.error
import urllib.request
from dataclasses import dataclass

from app.core.cache import cache


@dataclass
class ProbeResult:
    name: str
    path: str
    status: int
    elapsed_ms: float
    cache_key: str | None


def _request_json(base_url: str, path: str) -> tuple[int, object, float]:
    url = f"{base_url.rstrip('/')}{path}"
    start = time.perf_counter()
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            body = response.read().decode("utf-8")
            elapsed_ms = (time.perf_counter() - start) * 1000
            return response.status, json.loads(body), elapsed_ms
    except urllib.error.HTTPError as exc:
        elapsed_ms = (time.perf_counter() - start) * 1000
        return exc.code, {"error": exc.reason}, elapsed_ms


def _extract_items(payload: object) -> list[dict]:
    if isinstance(payload, dict) and isinstance(payload.get("items"), list):
        return [item for item in payload["items"] if isinstance(item, dict)]
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    return []


def _clear_phase4_keys() -> int:
    return cache.delete_many_patterns(
        [
            "cache:videos:list:*",
            "cache:videos:recommended:*",
            "cache:feeds:*",
            "cache:subscriptions:creator_ids:*",
            "cache:users:providers",
            "cache:users:detail:*",
        ]
    )


def _probe_round(base_url: str, probes: list[tuple[str, str, str | None]]) -> list[ProbeResult]:
    results: list[ProbeResult] = []
    for name, path, cache_key in probes:
        status, _, elapsed = _request_json(base_url, path)
        results.append(ProbeResult(name=name, path=path, status=status, elapsed_ms=elapsed, cache_key=cache_key))
    return results


def _print_round(title: str, results: list[ProbeResult]) -> None:
    print(title)
    for result in results:
        key = result.cache_key or "-"
        print(
            f"  {result.name:20} status={result.status:<3} elapsed_ms={result.elapsed_ms:8.2f} cache_key={key}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Phase 4 cache acceptance smoke check")
    parser.add_argument("--base-url", default="http://localhost:8000", help="Backend base URL")
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")

    users_status, users_payload, _ = _request_json(base_url, "/users?limit=1&offset=0")
    videos_status, videos_payload, _ = _request_json(base_url, "/videos?limit=1&offset=0")

    users = _extract_items(users_payload)
    videos = _extract_items(videos_payload)

    user_id = int(users[0]["id"]) if users_status == 200 and users else None
    video_id = int(videos[0]["id"]) if videos_status == 200 and videos else None

    probes: list[tuple[str, str, str | None]] = [
        ("videos_list", "/videos?limit=20&offset=0", "cache:videos:list:20:0"),
        ("providers", "/users/providers", "cache:users:providers"),
    ]

    if video_id is not None:
        probes.append(
            (
                "recommended",
                f"/videos/{video_id}/recommended?limit=8",
                f"cache:videos:recommended:{video_id}:8",
            )
        )
    else:
        print("Skipping recommended probe: no videos available")

    if user_id is not None:
        probes.append(("feed", f"/users/{user_id}/feed?limit=20&offset=0", f"cache:feeds:{user_id}:20:0"))
    else:
        print("Skipping feed probe: no users available")

    cleared = _clear_phase4_keys()
    print(f"Cleared cache keys: {cleared}")

    first_round = _probe_round(base_url, probes)
    second_round = _probe_round(base_url, probes)

    _print_round("Round 1 (expected cold/miss)", first_round)
    _print_round("Round 2 (expected warm/hit)", second_round)

    db_backed_keys = ["cache:videos:list:20:0"]
    if video_id is not None:
        db_backed_keys.append(f"cache:videos:recommended:{video_id}:8")
    if user_id is not None:
        db_backed_keys.append(f"cache:feeds:{user_id}:20:0")
    keys_present = sum(1 for key in db_backed_keys if cache.client.exists(key))

    # Approximation: one DB-heavy read avoided per warm request where cache key exists.
    estimated_db_queries_avoided = sum(
        1
        for result in second_round
        if result.name in {"videos_list", "recommended", "feed"} and result.status == 200
    )

    print("Summary")
    print(f"  user_id={user_id} video_id={video_id}")
    print(f"  db_cache_keys_present={keys_present}/{len(db_backed_keys)}")
    print(f"  estimated_db_queries_avoided_on_round2={estimated_db_queries_avoided}")


if __name__ == "__main__":
    main()
