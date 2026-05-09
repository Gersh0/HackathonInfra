import redis.asyncio as aioredis
from fastapi import HTTPException, Request
from redis import Redis
from redis.exceptions import RedisError

from app.core.settings import settings


class RedisRateLimiter:
    def __init__(self, redis_url: str):
        self.redis = Redis.from_url(redis_url)
        self.async_redis: aioredis.Redis = aioredis.Redis.from_url(redis_url)

    def check(self, request: Request, scope: str, max_requests: int, window_seconds: int) -> None:
        client_ip = request.client.host if request.client else "unknown"
        route = request.scope.get("route")
        route_path = getattr(route, "path", "unknown")
        key = f"ratelimit:{scope}:{client_ip}:{route_path}"

        try:
            count = self.redis.incr(key)
            if count == 1:
                self.redis.expire(key, window_seconds)
        except RedisError:
            return

        if count > max_requests:
            raise HTTPException(status_code=429, detail="Too many requests")

    async def acheck(self, request: Request, scope: str, max_requests: int, window_seconds: int) -> None:
        client_ip = request.client.host if request.client else "unknown"
        route = request.scope.get("route")
        route_path = getattr(route, "path", "unknown")
        key = f"ratelimit:{scope}:{client_ip}:{route_path}"

        try:
            count = await self.async_redis.incr(key)
            if count == 1:
                await self.async_redis.expire(key, window_seconds)
        except RedisError:
            return

        if count > max_requests:
            raise HTTPException(status_code=429, detail="Too many requests")


rate_limiter = RedisRateLimiter(settings.redis_url)
