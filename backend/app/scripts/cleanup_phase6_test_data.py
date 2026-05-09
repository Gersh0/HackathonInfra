import argparse
import os
from dataclasses import dataclass

from redis import Redis

from app.core.database import SessionLocal
from app.core.settings import settings
from app.models.video import Video


@dataclass
class Candidate:
    id: int
    title: str
    file_path: str
    thumbnail_path: str | None


def _find_candidates(prefix: str) -> list[Candidate]:
    db = SessionLocal()
    try:
        rows = (
            db.query(Video)
            .filter(Video.title.ilike(f"{prefix}%"))
            .order_by(Video.id.asc())
            .all()
        )
        return [
            Candidate(
                id=row.id,
                title=row.title,
                file_path=row.file_path,
                thumbnail_path=row.thumbnail_path,
            )
            for row in rows
        ]
    finally:
        db.close()


def _delete_rows(video_ids: list[int]) -> int:
    if not video_ids:
        return 0

    db = SessionLocal()
    try:
        rows = db.query(Video).filter(Video.id.in_(video_ids)).all()
        for row in rows:
            db.delete(row)
        db.commit()
        return len(rows)
    finally:
        db.close()


def _delete_file(path_value: str | None) -> bool:
    if not path_value:
        return False
    if os.path.exists(path_value):
        os.remove(path_value)
        return True
    return False


def _clear_related_redis(video_ids: list[int]) -> tuple[int, int, int]:
    redis = Redis.from_url(settings.redis_url)
    deleted_keys = 0
    removed_views = 0
    removed_last_seen = 0

    keys_to_delete = [f"worker:video:metadata:{video_id}" for video_id in video_ids]
    if keys_to_delete:
        deleted_keys = int(redis.delete(*keys_to_delete))

    if video_ids:
        fields = [str(video_id) for video_id in video_ids]
        removed_views = int(redis.hdel("worker:analytics:video_views", *fields))
        removed_last_seen = int(redis.hdel("worker:analytics:last_seen", *fields))

    return deleted_keys, removed_views, removed_last_seen


def _clear_list_caches() -> int:
    redis = Redis.from_url(settings.redis_url)
    keys = list(redis.scan_iter(match="cache:videos:list:*", count=300))
    if not keys:
        return 0
    return int(redis.delete(*keys))


def main() -> None:
    parser = argparse.ArgumentParser(description="Cleanup phase6 test videos and related artifacts")
    parser.add_argument("--prefix", default="phase6-", help="Video title prefix to clean")
    parser.add_argument("--apply", action="store_true", help="Apply deletion (default is dry-run)")
    args = parser.parse_args()

    candidates = _find_candidates(args.prefix)

    print(f"candidates={len(candidates)} prefix={args.prefix}")
    for item in candidates:
        print(
            "  "
            f"id={item.id} title={item.title!r} "
            f"file_exists={os.path.exists(item.file_path)} "
            f"thumb_exists={os.path.exists(item.thumbnail_path) if item.thumbnail_path else False}"
        )

    if not args.apply:
        print("dry_run=1 (no changes applied)")
        return

    video_ids = [item.id for item in candidates]

    deleted_files = 0
    for item in candidates:
        if _delete_file(item.file_path):
            deleted_files += 1
        if _delete_file(item.thumbnail_path):
            deleted_files += 1

    deleted_rows = _delete_rows(video_ids)
    deleted_metadata_keys, deleted_views_fields, deleted_last_seen_fields = _clear_related_redis(video_ids)
    deleted_cache_keys = _clear_list_caches()

    print("apply=1")
    print(f"deleted_rows={deleted_rows}")
    print(f"deleted_files={deleted_files}")
    print(f"deleted_metadata_keys={deleted_metadata_keys}")
    print(f"deleted_analytics_views_fields={deleted_views_fields}")
    print(f"deleted_analytics_last_seen_fields={deleted_last_seen_fields}")
    print(f"deleted_cache_keys={deleted_cache_keys}")


if __name__ == "__main__":
    main()
