import logging
import mimetypes
from datetime import datetime, timedelta, timezone
from pathlib import Path

from rq import Queue
from sqlalchemy import text

from app.core.cache import cache
from app.core.database import SessionLocal
from app.models.video import Video

logger = logging.getLogger(__name__)


def process_video_upload(video_id: int) -> None:
    db = SessionLocal()
    try:
        video = db.query(Video).filter(Video.id == video_id).first()
        if video is None:
            return

        file_path = Path(video.file_path)
        if not file_path.exists():
            return

        _store_video_metadata(video_id=video_id, file_path=file_path)

        if not video.thumbnail_path or not Path(video.thumbnail_path).exists():
            generated = _generate_fallback_thumbnail(video_id=video_id, file_path=file_path)
            video.thumbnail_path = str(generated)
            db.commit()
    finally:
        db.close()


def _store_video_metadata(video_id: int, file_path: Path) -> None:
    content_type = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
    metadata = {
        "file_name": file_path.name,
        "size_bytes": str(file_path.stat().st_size),
        "mime_type": content_type,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    cache.client.hset(f"worker:video:metadata:{video_id}", mapping=metadata)


def _generate_fallback_thumbnail(video_id: int, file_path: Path) -> Path:
    thumbnail_dir = file_path.parent / "thumbnails"
    thumbnail_dir.mkdir(parents=True, exist_ok=True)
    output = thumbnail_dir / f"generated_{video_id}.gif"

    # 1x1 transparent GIF, fast to generate and browser-compatible.
    gif_pixel = (
        b"GIF89a"
        b"\x01\x00\x01\x00"
        b"\x80\x00\x00"
        b"\x00\x00\x00"
        b"\xff\xff\xff"
        b"!\xf9\x04\x01\x00\x00\x00\x00"
        b",\x00\x00\x00\x00\x01\x00\x01\x00\x00"
        b"\x02\x02D\x01\x00"
        b";"
    )
    with output.open("wb") as fp:
        fp.write(gif_pixel)

    return output


def flush_view_counts_to_db() -> None:
    """Flush all Redis view count buffers to database. Runs every 30 seconds."""
    db = SessionLocal()
    try:
        view_increments = cache.get_all_view_counts()
        if not view_increments:
            logger.debug("flush_view_counts: no buffered counts to flush")
        else:
            logger.info("flush_view_counts: flushing %d video view counts", len(view_increments))
            try:
                values_list = [f"({video_id}, {increment})" for video_id, increment in view_increments.items()]
                values_clause = ", ".join(values_list)
                sql = text(f"""
                    UPDATE videos
                    SET views = videos.views + increments.increment_val
                    FROM (VALUES {values_clause}) AS increments(video_id, increment_val)
                    WHERE videos.id = increments.video_id
                """)
                db.execute(sql)
                db.commit()
                cache.delete_view_counts(list(view_increments.keys()))
                logger.info("flush_view_counts: updated %d videos", len(view_increments))
            except Exception:
                logger.exception("flush_view_counts: bulk update failed, rolling back")
                db.rollback()
    except Exception:
        logger.exception("flush_view_counts: unexpected error during flush")
    finally:
        db.close()
        try:
            Queue("default", connection=cache.client).enqueue_in(
                timedelta(seconds=30),
                flush_view_counts_to_db,
                job_timeout=120,
                job_id="periodic_flush_view_counts",
            )
        except Exception:
            logger.exception("flush_view_counts: failed to schedule next flush")


def process_analytics_batch() -> None:
    """Process all aggregated analytics events in batch. Runs every 30 seconds."""
    try:
        analytics_data = cache.get_all_analytics_events()
        if not analytics_data:
            logger.debug("process_analytics_batch: no aggregated events to process")
        else:
            total_events = sum(len(events) for events in analytics_data.values())
            logger.info(
                "process_analytics_batch: processing %d event types with %d total events",
                len(analytics_data),
                total_events,
            )
            current_time = datetime.now(timezone.utc).isoformat()
            processed_keys: list[str] = []
            for event_type, video_events in analytics_data.items():
                try:
                    pipe = cache.client.pipeline()
                    event_keys: list[str] = []
                    for video_id, count in video_events.items():
                        pipe.hincrby(f"worker:analytics:{event_type}_total", str(video_id), count)
                        pipe.hset("worker:analytics:last_processed", f"{event_type}:{video_id}", current_time)
                        event_keys.append(f"analytics:{event_type}:video:{video_id}")
                    pipe.execute()
                    processed_keys.extend(event_keys)
                    logger.info("process_analytics_batch: processed %d %s events", len(video_events), event_type)
                except Exception:
                    logger.exception("process_analytics_batch: failed to process %s events", event_type)

            if processed_keys:
                cache.delete_analytics_events(processed_keys)
                logger.info("process_analytics_batch: cleaned up %d processed keys", len(processed_keys))
    except Exception:
        logger.exception("process_analytics_batch: unexpected error during batch processing")
    finally:
        try:
            Queue("default", connection=cache.client).enqueue_in(
                timedelta(seconds=30),
                process_analytics_batch,
                job_timeout=120,
                job_id="periodic_process_analytics_batch",
            )
        except Exception:
            logger.exception("process_analytics_batch: failed to schedule next batch processing")
