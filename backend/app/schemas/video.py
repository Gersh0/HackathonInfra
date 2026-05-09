from datetime import datetime

from pydantic import BaseModel


class VideoUploaderResponse(BaseModel):
    id: int
    display_name: str
    avatar_url: str | None


class VideoBase(BaseModel):
    title: str
    description: str


class VideoResponse(VideoBase):
    id: int
    created_at: datetime
    views: int
    stream_url: str
    thumbnail_url: str | None = None
    uploader: VideoUploaderResponse | None = None

    model_config = {"from_attributes": True}
