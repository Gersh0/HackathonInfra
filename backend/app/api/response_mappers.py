from pathlib import Path, PurePosixPath

from app.schemas.user import UserResponse
from app.schemas.video import VideoResponse


def to_user_response(user) -> UserResponse:
    return UserResponse(
        id=user.id,
        display_name=user.display_name,
        avatar_url=to_upload_url(user.avatar_path) if user.avatar_path else None,
        created_at=user.created_at,
    )


def to_upload_url(path_value: str) -> str:
    normalized = path_value.replace("\\", "/")

    # Extract the portion after the uploads/ marker.
    marker = "uploads/"
    idx = normalized.rfind(marker)
    if idx != -1:
        relative = normalized[idx + len(marker):]
    else:
        relative = Path(normalized).name

    # Keep only safe relative segments and drop traversal markers.
    parts = [part for part in PurePosixPath(relative).parts if part not in ("", ".", "..")]
    if not parts:
        fallback = Path(normalized).name
        if not fallback:
            return "/uploads"
        parts = [fallback]

    safe_name = "/".join(parts)

    return f"/uploads/{safe_name}"


def to_video_response(video) -> VideoResponse:
    uploader = None
    if video.uploader:
        uploader = {
            "id": video.uploader.id,
            "display_name": video.uploader.display_name,
            "avatar_url": to_upload_url(video.uploader.avatar_path) if video.uploader.avatar_path else None,
        }

    return VideoResponse(
        id=video.id,
        title=video.title,
        description=video.description,
        created_at=video.created_at,
        views=video.views,
        stream_url=to_upload_url(video.file_path),
        thumbnail_url=to_upload_url(video.thumbnail_path) if video.thumbnail_path else None,
        uploader=uploader,
    )
