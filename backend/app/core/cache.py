import asyncio
import json
import logging
import random
from collections.abc import Iterable
from datetime import datetime
from typing import Any

import redis.asyncio as aioredis
from redis import Redis
from redis.exceptions import RedisError

from app.core.settings import settings

logger = logging.getLogger(__name__)


class RedisCache:
    def __init__(self, redis_url: str):
        self.client = Redis.from_url(
            redis_url,
            decode_responses=True,
            max_connections=settings.redis_max_connections,
        )

    def get_json(self, key: str) -> Any | None:
        try:
            raw = self.client.get(key)
        except RedisError as exc:
            logger.warning("cache get failed for key=%s error=%s", key, exc)
            return None

        if raw is None:
            return None

        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            logger.warning("cache decode failed for key=%s", key)
            return None

    def set_json(self, key: str, value: Any, ttl_seconds: int, jitter_ratio: float = 0.2) -> None:
        ttl = max(1, int(ttl_seconds + random.uniform(0, ttl_seconds * jitter_ratio)))
        try:
            self.client.setex(key, ttl, json.dumps(value))
        except RedisError as exc:
            logger.warning("cache set failed for key=%s error=%s", key, exc)

    def delete(self, key: str) -> None:
        try:
            self.client.delete(key)
        except RedisError as exc:
            logger.warning("cache delete failed for key=%s error=%s", key, exc)

    def delete_by_pattern(self, pattern: str) -> int:
        try:
            keys = list(self.client.scan_iter(match=pattern, count=200))
            if not keys:
                return 0
            return int(self.client.unlink(*keys))
        except RedisError as exc:
            logger.warning("cache pattern delete failed for pattern=%s error=%s", pattern, exc)
            return 0

    def delete_many_patterns(self, patterns: Iterable[str]) -> int:
        deleted = 0
        for pattern in patterns:
            deleted += self.delete_by_pattern(pattern)
        return deleted

    def acquire_soft_lock(self, key: str, ttl_seconds: int) -> bool:
        try:
            return bool(self.client.set(name=key, value="1", ex=max(1, ttl_seconds), nx=True))
        except RedisError as exc:
            logger.warning("cache lock acquisition failed for key=%s error=%s", key, exc)
            return False

    def release_soft_lock(self, key: str) -> None:
        self.delete(key)

    def write_with_lock(self, key: str, value: Any, ttl_seconds: int) -> None:
        """Acquire soft lock, write to cache, release lock. No-op if lock is unavailable."""
        lock_key = f"lock:{key}"
        has_lock = self.acquire_soft_lock(lock_key, ttl_seconds=4)
        if has_lock:
            try:
                self.set_json(key, value, ttl_seconds=ttl_seconds)
            finally:
                self.release_soft_lock(lock_key)

    def increment_view_count(self, video_id: int) -> None:
        """Increment view count in Redis buffer. Non-blocking, fails silently on Redis error."""
        try:
            self.client.incr(f"views:video:{video_id}")
        except RedisError as exc:
            logger.warning("view_count_incr failed video_id=%s error=%s", video_id, exc)

    def get_view_count(self, video_id: int) -> int:
        """Get buffered view count from Redis. Returns 0 if key doesn't exist or on error."""
        try:
            count = self.client.get(f"views:video:{video_id}")
            return int(count) if count is not None else 0
        except (RedisError, ValueError) as exc:
            logger.warning("view_count_get failed video_id=%s error=%s", video_id, exc)
            return 0

    def increment_and_get_view_count(self, video_id: int) -> int:
        """Increment view count and return new value in a single INCR roundtrip."""
        try:
            return int(self.client.incr(f"views:video:{video_id}"))
        except (RedisError, ValueError) as exc:
            logger.warning("view_count_incr_get failed video_id=%s error=%s", video_id, exc)
            return 0

    def get_all_view_counts(self) -> dict[int, int]:
        """Get all buffered view counts. Returns dict of {video_id: count}."""
        try:
            keys = list(self.client.scan_iter(match="views:video:*", count=200))
            if not keys:
                return {}

            pipe = self.client.pipeline()
            for key in keys:
                pipe.get(key)
            values = pipe.execute()

            result = {}
            for key, value in zip(keys, values, strict=False):
                if value is not None:
                    try:
                        video_id = int(key.split(":")[-1])
                        result[video_id] = int(value)
                    except ValueError:
                        continue

            return result
        except RedisError as exc:
            logger.warning("view_counts_get_all failed error=%s", exc)
            return {}

    def delete_view_counts(self, video_ids: list[int]) -> None:
        """Delete buffered view count keys after flushing to DB."""
        if not video_ids:
            return

        try:
            keys = [f"views:video:{video_id}" for video_id in video_ids]
            self.client.delete(*keys)
        except RedisError as exc:
            logger.warning("view_counts_delete failed video_ids=%s error=%s", video_ids, exc)

    def increment_analytics_event(self, video_id: int, event_type: str = "view") -> None:
        """Aggregate analytics events in Redis. Non-blocking, fails silently on Redis error."""
        try:
            self.client.incr(f"analytics:{event_type}:video:{video_id}")
            if event_type == "view":
                hour_key = datetime.now().strftime("%Y%m%d%H")
                self.client.sadd(f"analytics:hourly:{hour_key}", str(video_id))
        except RedisError as exc:
            logger.warning("analytics_incr failed video_id=%s event_type=%s error=%s", video_id, event_type, exc)

    def get_all_analytics_events(self) -> dict[str, dict[int, int]]:
        """Get all aggregated analytics events. Returns dict of {event_type: {video_id: count}}."""
        try:
            keys = list(self.client.scan_iter(match="analytics:*:video:*", count=200))
            if not keys:
                return {}

            pipe = self.client.pipeline()
            for key in keys:
                pipe.get(key)
            values = pipe.execute()

            result = {}
            for key, value in zip(keys, values, strict=False):
                if value is not None:
                    try:
                        parts = key.split(":")
                        if len(parts) >= 4:
                            event_type = parts[1]
                            video_id = int(parts[3])
                            count = int(value)

                            if event_type not in result:
                                result[event_type] = {}
                            result[event_type][video_id] = count
                    except (ValueError, IndexError):
                        continue

            return result
        except RedisError as exc:
            logger.warning("analytics_get_all failed error=%s", exc)
            return {}

    def delete_analytics_events(self, event_keys: list[str]) -> None:
        """Delete processed analytics event keys."""
        if not event_keys:
            return

        try:
            self.client.delete(*event_keys)
        except RedisError as exc:
            logger.warning("analytics_delete failed keys=%s error=%s", event_keys, exc)


class AsyncRedisCache:
    def __init__(self, redis_url: str):
        self.client: aioredis.Redis = aioredis.Redis.from_url(
            redis_url,
            decode_responses=True,
            max_connections=settings.redis_max_connections,
        )

    async def get_json(self, key: str) -> Any | None:
        try:
            raw = await self.client.get(key)
        except RedisError as exc:
            logger.warning("cache get failed for key=%s error=%s", key, exc)
            return None

        if raw is None:
            return None

        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            logger.warning("cache decode failed for key=%s", key)
            return None

    async def set_json(self, key: str, value: Any, ttl_seconds: int, jitter_ratio: float = 0.2) -> None:
        ttl = max(1, int(ttl_seconds + random.uniform(0, ttl_seconds * jitter_ratio)))
        try:
            await self.client.setex(key, ttl, json.dumps(value))
        except RedisError as exc:
            logger.warning("cache set failed for key=%s error=%s", key, exc)

    async def delete(self, key: str) -> None:
        try:
            await self.client.delete(key)
        except RedisError as exc:
            logger.warning("cache delete failed for key=%s error=%s", key, exc)

    async def delete_by_pattern(self, pattern: str) -> int:
        try:
            keys = []
            async for key in self.client.scan_iter(match=pattern, count=200):
                keys.append(key)
            if not keys:
                return 0
            return int(await self.client.unlink(*keys))
        except RedisError as exc:
            logger.warning("cache pattern delete failed for pattern=%s error=%s", pattern, exc)
            return 0

    async def delete_many_patterns(self, patterns: Iterable[str]) -> int:
        results = await asyncio.gather(
            *[self.delete_by_pattern(pattern) for pattern in patterns]
        )
        return sum(results)

    async def acquire_soft_lock(self, key: str, ttl_seconds: int) -> bool:
        try:
            return bool(await self.client.set(name=key, value="1", ex=max(1, ttl_seconds), nx=True))
        except RedisError as exc:
            logger.warning("cache lock acquisition failed for key=%s error=%s", key, exc)
            return False

    async def release_soft_lock(self, key: str) -> None:
        await self.delete(key)

    async def write_with_lock(self, key: str, value: Any, ttl_seconds: int) -> None:
        lock_key = f"lock:{key}"
        has_lock = await self.acquire_soft_lock(lock_key, ttl_seconds=4)
        if has_lock:
            try:
                await self.set_json(key, value, ttl_seconds=ttl_seconds)
            finally:
                await self.release_soft_lock(lock_key)

    async def increment_view_count(self, video_id: int) -> None:
        try:
            await self.client.incr(f"views:video:{video_id}")
        except RedisError as exc:
            logger.warning("view_count_incr failed video_id=%s error=%s", video_id, exc)

    async def get_view_count(self, video_id: int) -> int:
        try:
            count = await self.client.get(f"views:video:{video_id}")
            return int(count) if count is not None else 0
        except (RedisError, ValueError) as exc:
            logger.warning("view_count_get failed video_id=%s error=%s", video_id, exc)
            return 0

    async def increment_and_get_view_count(self, video_id: int) -> int:
        try:
            return int(await self.client.incr(f"views:video:{video_id}"))
        except (RedisError, ValueError) as exc:
            logger.warning("view_count_incr_get failed video_id=%s error=%s", video_id, exc)
            return 0

    async def increment_analytics_event(self, video_id: int, event_type: str = "view") -> None:
        try:
            await self.client.incr(f"analytics:{event_type}:video:{video_id}")
            if event_type == "view":
                hour_key = datetime.now().strftime("%Y%m%d%H")
                await self.client.sadd(f"analytics:hourly:{hour_key}", str(video_id))
        except RedisError as exc:
            logger.warning("analytics_incr failed video_id=%s event_type=%s error=%s", video_id, event_type, exc)


cache = RedisCache(settings.redis_url)
async_cache = AsyncRedisCache(settings.redis_url)
