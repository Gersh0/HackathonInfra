from typing import Protocol

from app.models.comment import Comment
from app.models.subscription import Subscription
from app.models.user import User
from app.models.user_identity import UserIdentity
from app.models.video import Video


class VideoRepositoryPort(Protocol):
    async def get_all(self, limit: int, offset: int, query: str | None = None) -> list[Video]: ...

    async def count_all(self, query: str | None = None) -> int: ...

    async def get_by_id(self, video_id: int) -> Video | None: ...

    async def get_by_uploader_ids(
        self, uploader_ids: list[int], limit: int, offset: int, query: str | None = None
    ) -> list[Video]: ...

    async def count_by_uploader_ids(self, uploader_ids: list[int], query: str | None = None) -> int: ...

    async def get_recommended_by_title_terms(
        self, exclude_video_id: int, terms: list[str], limit: int
    ) -> list[Video]: ...

    async def create(
        self,
        title: str,
        description: str,
        file_path: str,
        thumbnail_path: str | None = None,
        uploader_id: int | None = None,
    ) -> Video: ...

    async def increment_views(self, video: Video) -> Video: ...

    async def delete(self, video: Video) -> None: ...


class CommentRepositoryPort(Protocol):
    async def get_by_video_id(self, video_id: int, limit: int, offset: int) -> list[Comment]: ...

    async def count_by_video_id(self, video_id: int) -> int: ...

    async def create(self, video_id: int, author: str, content: str) -> Comment: ...


class UserRepositoryPort(Protocol):
    async def list_users(self, limit: int, offset: int, query: str | None = None) -> list[User]: ...

    async def count_users(self, query: str | None = None) -> int: ...

    async def get_by_id(self, user_id: int) -> User | None: ...

    async def get_by_provider_subject(self, provider: str, provider_subject: str) -> User | None: ...

    async def create_user(self, display_name: str, avatar_path: str | None = None) -> User: ...

    async def create_identity(
        self,
        user_id: int,
        provider: str,
        provider_subject: str,
        email: str | None = None,
    ) -> UserIdentity: ...

    async def create_user_with_identity(
        self,
        display_name: str,
        provider: str,
        provider_subject: str,
        avatar_path: str | None = None,
        email: str | None = None,
    ) -> User: ...

    async def commit(self) -> None: ...

    async def refresh_user(self, user: User) -> None: ...


class SubscriptionRepositoryPort(Protocol):
    async def get_by_pair(self, follower_id: int, creator_id: int) -> Subscription | None: ...

    async def list_creator_ids(self, follower_id: int, limit: int, offset: int) -> list[int]: ...

    async def list_all_creator_ids(self, follower_id: int) -> list[int]: ...

    async def create(self, follower_id: int, creator_id: int) -> Subscription: ...

    async def delete(self, subscription: Subscription) -> None: ...
