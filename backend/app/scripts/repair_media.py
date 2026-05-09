import argparse
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.database import SessionLocal
from app.models.video import Video


def resolve_storage_path(path_value: str) -> Path:
    normalized = path_value.replace("\\", "/")

    if normalized.startswith("uploads/"):
        return Path(normalized)

    marker = "/uploads/"
    if marker in normalized:
        return Path("uploads") / normalized.split(marker, maxsplit=1)[1]

    return Path("uploads") / Path(normalized).name


def repair_media(db: Session, delete_orphans: bool, null_missing_thumbnails: bool) -> int:
    videos = db.scalars(select(Video).order_by(Video.id.asc())).all()

    total = len(videos)
    orphan_videos = 0
    missing_thumbnails = 0
    deleted = 0
    nulled = 0

    for video in videos:
        stream_path = resolve_storage_path(video.file_path)
        stream_exists = stream_path.exists()

        thumbnail_exists = True
        thumbnail_path: Path | None = None
        if video.thumbnail_path:
            thumbnail_path = resolve_storage_path(video.thumbnail_path)
            thumbnail_exists = thumbnail_path.exists()

        if not stream_exists:
            orphan_videos += 1
            print(
                f"ORPHAN_VIDEO id={video.id} title={video.title!r} "
                f"stream_path={stream_path.as_posix()}"
            )
            if delete_orphans:
                db.delete(video)
                deleted += 1
            continue

        if video.thumbnail_path and not thumbnail_exists:
            missing_thumbnails += 1
            print(
                f"MISSING_THUMBNAIL id={video.id} title={video.title!r} "
                f"thumbnail_path={thumbnail_path.as_posix() if thumbnail_path else ''}"
            )
            if null_missing_thumbnails:
                video.thumbnail_path = None
                nulled += 1

    if delete_orphans or null_missing_thumbnails:
        db.commit()

    print("SUMMARY")
    print(f"total_videos={total}")
    print(f"orphan_videos={orphan_videos}")
    print(f"missing_thumbnails={missing_thumbnails}")
    print(f"deleted_orphan_videos={deleted}")
    print(f"nulled_thumbnails={nulled}")

    return orphan_videos + missing_thumbnails


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Audit and optionally repair videos with missing media files."
    )
    parser.add_argument(
        "--delete-orphans",
        action="store_true",
        help="Delete videos whose stream files are missing.",
    )
    parser.add_argument(
        "--null-missing-thumbnails",
        action="store_true",
        help="Set thumbnail_path to NULL when thumbnail files are missing.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    db = SessionLocal()
    try:
        findings = repair_media(
            db=db,
            delete_orphans=args.delete_orphans,
            null_missing_thumbnails=args.null_missing_thumbnails,
        )
    finally:
        db.close()

    if findings == 0:
        print("No issues found.")


if __name__ == "__main__":
    main()
