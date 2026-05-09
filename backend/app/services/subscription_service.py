import logging

from fastapi import HTTPException

from app.core.cache import AsyncRedisCache
from app.models.subscription import Subscription
from app.models.video import Video
from app.repositories.interfaces import SubscriptionRepositoryPort, UserRepositoryPort, VideoRepositoryPort
from app.services.cache_payloads import payload_to_videos, videos_to_payload

logger = logging.getLogger(__name__)


class SubscriptionService:
    def __init__(
        self,
        user_repo: UserRepositoryPort,
        subscription_repo: SubscriptionRepositoryPort,
        video_repo: VideoRepositoryPort,
        cache: AsyncRedisCache,
    ):
        self.user_repo = user_repo
        self.subscription_repo = subscription_repo
        self.video_repo = video_repo
        self.cache = cache

    async def subscribe(self, follower_id: int, creator_id: int) -> Subscription:
        await self._ensure_user_exists(follower_id)
        await self._ensure_user_exists(creator_id)

        if follower_id == creator_id:
            raise HTTPException(status_code=400, detail="Cannot subscribe to yourself")

        existing = await self.subscription_repo.get_by_pair(follower_id=follower_id, creator_id=creator_id)
        if existing:
            return existing

        created = await self.subscription_repo.create(follower_id=follower_id, creator_id=creator_id)
        await self._invalidate_subscription_cache(follower_id=follower_id)
        return created

    async def unsubscribe(self, follower_id: int, creator_id: int) -> None:
        await self._ensure_user_exists(follower_id)
        await self._ensure_user_exists(creator_id)

        existing = await self.subscription_repo.get_by_pair(follower_id=follower_id, creator_id=creator_id)
        if not existing:
            return

        await self.subscription_repo.delete(existing)
        await self._invalidate_subscription_cache(follower_id=follower_id)

    async def list_subscription_creator_ids(self, follower_id: int, limit: int, offset: int) -> list[int]:
        key = f"cache:subscriptions:creator_ids:{follower_id}:{limit}:{offset}"
        cached = await self.cache.get_json(key)
        if isinstance(cached, list):
            logger.info("cache_hit endpoint=subscriptions_creator_ids key=%s", key)
            return [int(item) for item in cached]

        logger.info("cache_miss endpoint=subscriptions_creator_ids key=%s", key)
        creator_ids = await self.subscription_repo.list_creator_ids(follower_id=follower_id, limit=limit, offset=offset)
        await self.cache.write_with_lock(key, creator_ids, ttl_seconds=30)
        return creator_ids

    async def get_subscription_feed(
        self, follower_id: int, limit: int, offset: int, query: str | None = None
    ) -> list[Video]:
        normalized_query = (query or "").strip().lower()
        key = f"cache:feeds:{follower_id}:{limit}:{offset}:{normalized_query}"
        cached = await self.cache.get_json(key)
        if isinstance(cached, list):
            logger.info("cache_hit endpoint=subscriptions_feed key=%s", key)
            return payload_to_videos(cached)

        logger.info("cache_miss endpoint=subscriptions_feed key=%s", key)
        creator_ids = await self.list_subscription_creator_ids(follower_id=follower_id, limit=limit, offset=offset)
        videos = await self.video_repo.get_by_uploader_ids(
            creator_ids,
            limit=limit,
            offset=offset,
            query=normalized_query or None,
        )
        await self.cache.write_with_lock(key, videos_to_payload(videos), ttl_seconds=30)
        return videos

    async def count_subscription_feed(self, follower_id: int, query: str | None = None) -> int:
        creator_ids = await self.subscription_repo.list_all_creator_ids(follower_id=follower_id)
        normalized_query = (query or "").strip().lower()
        return await self.video_repo.count_by_uploader_ids(creator_ids, query=normalized_query or None)

    async def is_subscribed(self, follower_id: int, creator_id: int) -> bool:
        if follower_id == creator_id:
            return False
        existing = await self.subscription_repo.get_by_pair(follower_id=follower_id, creator_id=creator_id)
        return existing is not None

    async def _ensure_user_exists(self, user_id: int) -> None:
        if not await self.user_repo.get_by_id(user_id):
            raise HTTPException(status_code=404, detail="User not found")

    async def _invalidate_subscription_cache(self, follower_id: int) -> None:
        deleted = await self.cache.delete_many_patterns(
            [
                f"cache:subscriptions:creator_ids:{follower_id}:*",
                f"cache:feeds:{follower_id}:*",
            ]
        )
        logger.info("cache_invalidate scope=subscriptions follower_id=%s deleted=%s", follower_id, deleted)
