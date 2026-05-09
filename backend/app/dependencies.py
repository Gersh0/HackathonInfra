from fastapi import Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.async_jobs.dispatcher import JobDispatcher, job_dispatcher
from app.auth.providers import UserProviderRegistry, UserProviderRegistryPort
from app.core.cache import AsyncRedisCache, async_cache
from app.core.database import get_db
from app.core.rate_limit import rate_limiter
from app.core.settings import settings
from app.repositories.comment_repository import CommentRepository
from app.repositories.interfaces import (
    CommentRepositoryPort,
    SubscriptionRepositoryPort,
    UserRepositoryPort,
    VideoRepositoryPort,
)
from app.repositories.subscription_repository import SubscriptionRepository
from app.repositories.user_repository import UserRepository
from app.repositories.video_repository import VideoRepository
from app.services.comment_service import CommentService
from app.services.interfaces import CommentServicePort, SubscriptionServicePort, UserServicePort, VideoServicePort
from app.services.subscription_service import SubscriptionService
from app.services.user_service import UserService
from app.services.video_service import VideoService


def get_video_repository(db: AsyncSession = Depends(get_db)) -> VideoRepositoryPort:
    return VideoRepository(db)


def get_comment_repository(db: AsyncSession = Depends(get_db)) -> CommentRepositoryPort:
    return CommentRepository(db)


def get_user_repository(db: AsyncSession = Depends(get_db)) -> UserRepositoryPort:
    return UserRepository(db)


def get_subscription_repository(db: AsyncSession = Depends(get_db)) -> SubscriptionRepositoryPort:
    return SubscriptionRepository(db)


def get_user_provider_registry() -> UserProviderRegistryPort:
    return UserProviderRegistry()


def get_cache() -> AsyncRedisCache:
    return async_cache


def get_job_dispatcher() -> JobDispatcher:
    return job_dispatcher


async def rate_limit_mutations(request: Request) -> None:
    await rate_limiter.acheck(
        request=request,
        scope="mutation",
        max_requests=settings.rate_limit_mutation_max_requests,
        window_seconds=settings.rate_limit_window_seconds,
    )


async def rate_limit_auth(request: Request) -> None:
    await rate_limiter.acheck(
        request=request,
        scope="auth",
        max_requests=settings.rate_limit_auth_max_requests,
        window_seconds=settings.rate_limit_window_seconds,
    )


def get_video_service(
    video_repo: VideoRepositoryPort = Depends(get_video_repository),
    user_repo: UserRepositoryPort = Depends(get_user_repository),
    redis_cache: AsyncRedisCache = Depends(get_cache),
    dispatcher: JobDispatcher = Depends(get_job_dispatcher),
) -> VideoServicePort:
    return VideoService(repo=video_repo, user_repo=user_repo, cache=redis_cache, dispatcher=dispatcher)


def get_comment_service(
    comment_repo: CommentRepositoryPort = Depends(get_comment_repository),
    video_repo: VideoRepositoryPort = Depends(get_video_repository),
) -> CommentServicePort:
    return CommentService(comment_repo=comment_repo, video_repo=video_repo)


def get_user_service(
    user_repo: UserRepositoryPort = Depends(get_user_repository),
    provider_registry: UserProviderRegistryPort = Depends(get_user_provider_registry),
    redis_cache: AsyncRedisCache = Depends(get_cache),
) -> UserServicePort:
    return UserService(repo=user_repo, provider_registry=provider_registry, cache=redis_cache)


def get_subscription_service(
    user_repo: UserRepositoryPort = Depends(get_user_repository),
    subscription_repo: SubscriptionRepositoryPort = Depends(get_subscription_repository),
    video_repo: VideoRepositoryPort = Depends(get_video_repository),
    redis_cache: AsyncRedisCache = Depends(get_cache),
) -> SubscriptionServicePort:
    return SubscriptionService(
        user_repo=user_repo,
        subscription_repo=subscription_repo,
        video_repo=video_repo,
        cache=redis_cache,
    )
