import asyncio
import os
import shutil
import uuid
import logging
import time
from collections import deque
from pathlib import Path

from fastapi import HTTPException, UploadFile

from app.async_jobs.dispatcher import JobDispatcher
from app.core.cache import AsyncRedisCache
from app.core.settings import settings
from app.models.video import Video
from app.repositories.interfaces import UserRepositoryPort, VideoRepositoryPort
from app.services.cache_payloads import payload_to_videos, videos_to_payload

logger = logging.getLogger(__name__)

UPLOAD_COPY_BUFFER_BYTES = 1024 * 1024

# In-memory buffer for analytics events. deque.append is thread-safe under CPython's GIL
# and costs nanoseconds — zero Redis pressure on the hot path.
_analytics_buffer: deque[tuple[int, str]] = deque()
ANALYTICS_FLUSH_INTERVAL_S = 5


async def _analytics_flush_loop(cache: AsyncRedisCache) -> None:
    while True:
        await asyncio.sleep(ANALYTICS_FLUSH_INTERVAL_S)
        while _analytics_buffer:
            try:
                video_id, event_type = _analytics_buffer.popleft()
                await cache.increment_analytics_event(video_id, event_type)
            except Exception:
                logger.exception("analytics_flush_error")


class VideoService:
    def __init__(
        self,
        repo: VideoRepositoryPort,
        user_repo: UserRepositoryPort,
        cache: AsyncRedisCache,
        dispatcher: JobDispatcher,
    ):
        self.repo = repo
        self.user_repo = user_repo
        self.cache = cache
        self.dispatcher = dispatcher

    async def list_videos(self, limit: int, offset: int, query: str | None = None) -> list[Video]:
        normalized_query = (query or "").strip().lower()
        key = f"cache:videos:list:{limit}:{offset}:{normalized_query}"
        cached = await self.cache.get_json(key)
        if isinstance(cached, list):
            logger.info("cache_hit endpoint=videos_list key=%s", key)
            return payload_to_videos(cached)

        logger.info("cache_miss endpoint=videos_list key=%s", key)
        videos = await self.repo.get_all(limit=limit, offset=offset, query=normalized_query or None)
        await self.cache.write_with_lock(key, videos_to_payload(videos), ttl_seconds=45)
        return videos

    async def count_videos(self, query: str | None = None) -> int:
        normalized_query = (query or "").strip().lower()
        return await self.repo.count_all(query=normalized_query or None)

    async def get_video(self, video_id: int) -> Video:
        video = await self.repo.get_by_id(video_id)
        if not video:
            raise HTTPException(status_code=404, detail="Video not found")
        return video

    async def upload_video(
        self,
        title: str,
        description: str,
        file: UploadFile,
        upload_dir: Path,
        thumbnail: UploadFile | None = None,
        uploader_id: int | None = None,
    ) -> Video:
        if uploader_id is not None and await self.user_repo.get_by_id(uploader_id) is None:
            raise HTTPException(status_code=404, detail="Uploader not found")

        self._validate_upload_size(file, max_size=settings.max_video_upload_bytes, label="Video")
        if thumbnail:
            if thumbnail.content_type and not thumbnail.content_type.startswith("image/"):
                raise HTTPException(status_code=400, detail="Thumbnail must be an image")
            self._validate_upload_size(thumbnail, max_size=settings.max_thumbnail_upload_bytes, label="Thumbnail")

        upload_dir.mkdir(parents=True, exist_ok=True)

        created: Video | None = None
        saved_paths: list[str] = []
        try:
            video_path = self._save_upload_file(file=file, directory=upload_dir, default_name="video.mp4")
            saved_paths.append(video_path)

            thumbnail_path: str | None = None
            if thumbnail:
                thumbnail_dir = upload_dir / "thumbnails"
                thumbnail_dir.mkdir(parents=True, exist_ok=True)
                thumbnail_path = self._save_upload_file(file=thumbnail, directory=thumbnail_dir, default_name="thumb.jpg")
                saved_paths.append(thumbnail_path)

            created = await self.repo.create(
                title=title,
                description=description,
                file_path=video_path,
                thumbnail_path=thumbnail_path,
                uploader_id=uploader_id,
            )
        except Exception:
            self._cleanup_media_files(saved_paths, upload_root=upload_dir)
            raise

        if created is None:
            raise HTTPException(status_code=500, detail="Video creation failed")

        try:
            self.dispatcher.enqueue_video_processing(created.id)
        except Exception:
            logger.exception("video_processing_enqueue_failed video_id=%s", created.id)
        await self._invalidate_video_related_cache()
        return created

    async def get_recommended(self, video_id: int, limit: int = 8) -> list[Video]:
        current = await self.get_video(video_id)
        key = f"cache:videos:recommended:{video_id}:{limit}"
        cached = await self.cache.get_json(key)
        if isinstance(cached, list):
            logger.info("cache_hit endpoint=videos_recommended key=%s", key)
            return payload_to_videos(cached)

        logger.info("cache_miss endpoint=videos_recommended key=%s", key)
        terms = sorted({term.strip().lower() for term in current.title.split() if len(term.strip()) >= 2})
        videos = await self.repo.get_recommended_by_title_terms(exclude_video_id=current.id, terms=terms, limit=limit)
        await self.cache.write_with_lock(key, videos_to_payload(videos), ttl_seconds=30)
        return videos

    async def get_video_with_view_increment(self, video_id: int) -> Video:
        """Get video and increment view count via Redis buffer. No synchronous DB write."""
        cache_key = f"cache:videos:detail:{video_id}"
        cached = await self.cache.get_json(cache_key)
        if isinstance(cached, dict):
            logger.info("cache_hit endpoint=video_detail key=%s", cache_key)
            video = payload_to_videos([cached])[0]
        else:
            logger.info("cache_miss endpoint=video_detail key=%s", cache_key)
            video = await self.get_video(video_id)
            await self.cache.write_with_lock(cache_key, videos_to_payload([video])[0], ttl_seconds=settings.video_detail_cache_ttl)

        buffered_views = await self.cache.increment_and_get_view_count(video_id)
        video.views += buffered_views

        _analytics_buffer.append((video.id, "view"))

        return video

    async def probe_video_redis(self, video_id: int) -> dict[str, float | int]:
        t0 = time.perf_counter()
        await self.cache.increment_view_count(video_id)
        t1 = time.perf_counter()
        buffered_views = await self.cache.get_view_count(video_id)
        t2 = time.perf_counter()
        try:
            await self.cache.increment_analytics_event(video_id, "view")
        except Exception:
            logger.exception("analytics_aggregation_failed video_id=%s", video_id)
        t3 = time.perf_counter()

        return {
            "video_id": video_id,
            "view_incr_ms": (t1 - t0) * 1000,
            "view_read_ms": (t2 - t1) * 1000,
            "analytics_ms": (t3 - t2) * 1000,
            "total_ms": (t3 - t0) * 1000,
            "buffered_views": buffered_views,
        }

    async def delete_video(self, video_id: int, requester_user_id: int) -> None:
        if await self.user_repo.get_by_id(requester_user_id) is None:
            raise HTTPException(status_code=404, detail="User not found")

        video = await self.get_video(video_id)
        if video.uploader_id is None or video.uploader_id != requester_user_id:
            raise HTTPException(status_code=403, detail="Only the video owner can delete this video")

        file_paths = [video.file_path]
        if video.thumbnail_path:
            file_paths.append(video.thumbnail_path)

        await self.repo.delete(video)
        await self._invalidate_video_related_cache()
        self._cleanup_media_files(file_paths, upload_root=Path("uploads"))

    async def _invalidate_video_related_cache(self) -> None:
        deleted = await self.cache.delete_many_patterns(
            [
                "cache:videos:list:*",
                "cache:videos:recommended:*",
                "cache:videos:detail:*",
                "cache:feeds:*",
            ]
        )
        logger.info("cache_invalidate scope=video_related deleted=%s", deleted)

    def _save_upload_file(self, file: UploadFile, directory: Path, default_name: str) -> str:
        suffix = Path(file.filename or default_name).suffix or Path(default_name).suffix
        filename = f"{uuid.uuid4()}{suffix}"
        destination = directory / filename

        with destination.open("wb") as buffer:
            file.file.seek(0)
            shutil.copyfileobj(file.file, buffer, length=UPLOAD_COPY_BUFFER_BYTES)

        return str(destination)

    def _validate_upload_size(self, upload: UploadFile, max_size: int, label: str) -> None:
        current_position = upload.file.tell()
        upload.file.seek(0, os.SEEK_END)
        size = upload.file.tell()
        upload.file.seek(current_position)
        if size > max_size:
            raise HTTPException(status_code=413, detail=f"{label} exceeds allowed size limit")

    def _cleanup_media_files(self, file_paths: list[str], upload_root: Path) -> None:
        root = upload_root.resolve()
        for file_path in file_paths:
            self._remove_media_file(path_value=file_path, root=root)

    def _remove_media_file(self, path_value: str, root: Path) -> None:
        candidate = Path(path_value)
        try:
            resolved = candidate.resolve()
        except OSError:
            logger.warning("media_cleanup_skip_invalid_path path=%s", path_value)
            return

        if resolved != root and root not in resolved.parents:
            logger.warning("media_cleanup_skip_outside_root path=%s root=%s", resolved, root)
            return

        if not resolved.exists():
            return

        if not resolved.is_file() and not resolved.is_symlink():
            logger.warning("media_cleanup_skip_non_file path=%s", resolved)
            return

        try:
            resolved.unlink()
        except OSError:
            logger.exception("media_cleanup_remove_failed path=%s", resolved)
            return

        current = resolved.parent
        while current != root and root in current.parents:
            try:
                current.rmdir()
            except OSError:
                break
            current = current.parent
