from datetime import datetime
from types import SimpleNamespace
from typing import Any


def _video_to_payload(video: Any) -> dict[str, Any]:
    uploader = None
    if getattr(video, "uploader", None):
        uploader = {
            "id": video.uploader.id,
            "display_name": video.uploader.display_name,
            "avatar_path": video.uploader.avatar_path,
        }

    return {
        "id": video.id,
        "title": video.title,
        "description": video.description,
        "created_at": video.created_at.isoformat(),
        "views": video.views,
        "file_path": video.file_path,
        "thumbnail_path": video.thumbnail_path,
        "uploader": uploader,
    }


def videos_to_payload(videos: list[Any]) -> list[dict[str, Any]]:
    return [_video_to_payload(video) for video in videos]


def payload_to_videos(payload: list[dict[str, Any]]) -> list[Any]:
    hydrated: list[Any] = []
    for item in payload:
        uploader_payload = item.get("uploader")
        uploader = None
        if uploader_payload:
            uploader = SimpleNamespace(
                id=uploader_payload["id"],
                display_name=uploader_payload["display_name"],
                avatar_path=uploader_payload.get("avatar_path"),
            )

        hydrated.append(
            SimpleNamespace(
                id=item["id"],
                title=item["title"],
                description=item["description"],
                created_at=datetime.fromisoformat(item["created_at"]),
                views=item["views"],
                file_path=item["file_path"],
                thumbnail_path=item.get("thumbnail_path"),
                uploader=uploader,
            )
        )
    return hydrated


def user_to_payload(user: Any) -> dict[str, Any]:
    return {
        "id": user.id,
        "display_name": user.display_name,
        "avatar_path": user.avatar_path,
        "created_at": user.created_at.isoformat(),
    }


def payload_to_user(payload: dict[str, Any]) -> Any:
    return SimpleNamespace(
        id=payload["id"],
        display_name=payload["display_name"],
        avatar_path=payload.get("avatar_path"),
        created_at=datetime.fromisoformat(payload["created_at"]),
    )
