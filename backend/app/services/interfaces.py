from pathlib import Path
from typing import Protocol

from fastapi import UploadFile

from app.models.comment import Comment
from app.models.subscription import Subscription
from app.models.user import User
from app.models.video import Video


class VideoServicePort(Protocol):
    async def list_videos(self, limit: int, offset: int, query: str | None = None) -> list[Video]: ...

    async def count_videos(self, query: str | None = None) -> int: ...

    async def get_video(self, video_id: int) -> Video: ...

    async def upload_video(
        self,
        title: str,
        description: str,
        file: UploadFile,
        upload_dir: Path,
        thumbnail: UploadFile | None = None,
        uploader_id: int | None = None,
    ) -> Video: ...

    async def get_recommended(self, video_id: int, limit: int = 8) -> list[Video]: ...

    async def get_video_with_view_increment(self, video_id: int) -> Video: ...

    async def probe_video_redis(self, video_id: int) -> dict[str, float | int]: ...

    async def delete_video(self, video_id: int, requester_user_id: int) -> None: ...


class CommentServicePort(Protocol):
    async def list_comments(self, video_id: int, limit: int, offset: int) -> list[Comment]: ...

    async def count_comments(self, video_id: int) -> int: ...

    async def create_comment(self, video_id: int, author: str, content: str) -> Comment: ...


class UserServicePort(Protocol):
    async def list_users(self, limit: int, offset: int, query: str | None = None) -> list[User]: ...

    async def count_users(self, query: str | None = None) -> int: ...

    async def get_user(self, user_id: int) -> User: ...

    async def create_user(
        self,
        provider_name: str,
        display_name: str,
        provider_subject: str,
        email: str | None,
        avatar: UploadFile | None,
        upload_dir: Path,
    ) -> User: ...

    async def list_providers(self) -> list[str]: ...


class SubscriptionServicePort(Protocol):
    async def subscribe(self, follower_id: int, creator_id: int) -> Subscription: ...

    async def unsubscribe(self, follower_id: int, creator_id: int) -> None: ...

    async def list_subscription_creator_ids(self, follower_id: int, limit: int, offset: int) -> list[int]: ...

    async def get_subscription_feed(
        self, follower_id: int, limit: int, offset: int, query: str | None = None
    ) -> list[Video]: ...

    async def count_subscription_feed(self, follower_id: int, query: str | None = None) -> int: ...
