import os
import shutil
import uuid
import logging
from pathlib import Path

from fastapi import HTTPException, UploadFile
from sqlalchemy.exc import IntegrityError

from app.auth.providers import ProviderUserCreateInput, UserProviderRegistryPort
from app.core.cache import AsyncRedisCache
from app.core.settings import settings
from app.models.user import User
from app.repositories.interfaces import UserRepositoryPort
from app.services.cache_payloads import payload_to_user, user_to_payload

logger = logging.getLogger(__name__)

UPLOAD_COPY_BUFFER_BYTES = 1024 * 1024


class UserService:
    def __init__(self, repo: UserRepositoryPort, provider_registry: UserProviderRegistryPort, cache: AsyncRedisCache):
        self.repo = repo
        self.provider_registry = provider_registry
        self.cache = cache

    async def list_users(self, limit: int, offset: int, query: str | None = None) -> list[User]:
        return await self.repo.list_users(limit=limit, offset=offset, query=query)

    async def count_users(self, query: str | None = None) -> int:
        return await self.repo.count_users(query=query)

    async def get_user(self, user_id: int) -> User:
        key = f"cache:users:detail:{user_id}"
        cached = await self.cache.get_json(key)
        if isinstance(cached, dict):
            logger.info("cache_hit endpoint=user_detail key=%s", key)
            return payload_to_user(cached)

        logger.info("cache_miss endpoint=user_detail key=%s", key)
        user = await self.repo.get_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found")

        await self.cache.write_with_lock(key, user_to_payload(user), ttl_seconds=120)
        return user

    async def create_user(
        self,
        provider_name: str,
        display_name: str,
        provider_subject: str,
        email: str | None,
        avatar: UploadFile | None,
        upload_dir: Path,
    ) -> User:
        provider = self.provider_registry.get(provider_name)

        payload = ProviderUserCreateInput(
            display_name=display_name.strip(),
            provider_subject=provider_subject,
            email=email,
            avatar_path=None,
        )
        if not payload.display_name:
            raise HTTPException(status_code=400, detail="display_name is required")

        normalized_subject = provider.normalize_subject(payload)

        existing = await self.repo.get_by_provider_subject(provider_name, normalized_subject)
        if existing:
            raise HTTPException(status_code=409, detail="A user for this provider subject already exists")

        avatar_path = self._save_avatar(avatar=avatar, upload_dir=upload_dir)

        try:
            user = await self.repo.create_user_with_identity(
                display_name=payload.display_name,
                avatar_path=avatar_path,
                provider=provider_name,
                provider_subject=normalized_subject,
                email=payload.email.strip() if payload.email else None,
            )
        except IntegrityError as exc:
            if avatar_path and os.path.exists(avatar_path):
                os.remove(avatar_path)
            raise HTTPException(status_code=409, detail="A user for this provider subject already exists") from exc
        except Exception:
            if avatar_path and os.path.exists(avatar_path):
                os.remove(avatar_path)
            raise

        await self._invalidate_user_related_cache(new_user_id=user.id)
        return user

    async def list_providers(self) -> list[str]:
        key = "cache:users:providers"
        cached = await self.cache.get_json(key)
        if isinstance(cached, list):
            logger.info("cache_hit endpoint=users_providers key=%s", key)
            return [str(item) for item in cached]

        logger.info("cache_miss endpoint=users_providers key=%s", key)
        providers = self.provider_registry.list_provider_names()
        await self.cache.write_with_lock(key, providers, ttl_seconds=300)
        return providers

    def _save_avatar(self, avatar: UploadFile | None, upload_dir: Path) -> str | None:
        if avatar is None:
            return None
        if avatar.content_type and not avatar.content_type.startswith("image/"):
            raise HTTPException(status_code=400, detail="Avatar must be an image")

        current_position = avatar.file.tell()
        avatar.file.seek(0, os.SEEK_END)
        avatar_size = avatar.file.tell()
        avatar.file.seek(current_position)
        if avatar_size > settings.max_avatar_upload_bytes:
            raise HTTPException(status_code=413, detail="Avatar exceeds allowed size limit")

        avatar_dir = upload_dir / "avatars"
        avatar_dir.mkdir(parents=True, exist_ok=True)

        suffix = Path(avatar.filename or "avatar.jpg").suffix or ".jpg"
        destination = avatar_dir / f"{uuid.uuid4()}{suffix}"

        with destination.open("wb") as buffer:
            avatar.file.seek(0)
            shutil.copyfileobj(avatar.file, buffer, length=UPLOAD_COPY_BUFFER_BYTES)

        return str(destination)

    async def _invalidate_user_related_cache(self, new_user_id: int) -> None:
        await self.cache.delete("cache:users:providers")
        await self.cache.delete(f"cache:users:detail:{new_user_id}")
        logger.info("cache_invalidate scope=user_related user_id=%s", new_user_id)
